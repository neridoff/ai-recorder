import Foundation
import AVFoundation
import os

public enum RecorderLog {
    public static let subsystem = "com.neridov.airecorder"
}

/// Источник звука для одной дорожки (системный звук или микрофон).
public protocol AudioCaptureSource: AnyObject {
    /// Имя дорожки: "system" или "mic". Совпадает с именем файла без расширения.
    var name: String { get }
    var deviceName: String { get }
    var nominalSampleRate: Double { get }
    var nominalChannels: Int { get }
    /// onBuffer: буфер и host time его первого сэмпла (тики mach_absolute_time),
    /// вызывается на потоке захвата. onFailure: ошибка во время записи
    /// (смена устройства, остановка потока); переподключения в E1 нет.
    func start(onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void,
               onFailure: @escaping (String) -> Void) async throws
    func stop() async
}

/// Одна запись: две дорожки, session.json со статусом recording с момента старта,
/// обновление метаданных каждые metadataInterval секунд.
public final class RecordingSession: @unchecked Sendable {
    public private(set) var directory: URL?

    private let store: SessionStore
    private let sources: [AudioCaptureSource]
    private let clock: HostClock
    private let metadataInterval: TimeInterval
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "session")

    private let lock = NSLock()
    private var base: SessionMetadata?          // под lock
    private var writers: [String: TrackWriter] = [:]
    private var timer: DispatchSourceTimer?
    private var flushFailed = false             // под lock
    /// Host time начала и конца отрезков записи (FR-14), под lock.
    private var periods: [(start: UInt64, end: UInt64?)] = []
    private let timerQueue = DispatchQueue(label: "airecorder.session.metadata", qos: .utility)

    public init(store: SessionStore,
                system: AudioCaptureSource,
                mic: AudioCaptureSource,
                clock: HostClock = .system,
                metadataInterval: TimeInterval = 5) {
        self.store = store
        self.sources = [system, mic]
        self.clock = clock
        self.metadataInterval = metadataInterval
    }

    /// startPressedHostTime — момент нажатия «Старт», для замера задержки до первого сэмпла (FR-01).
    public func start(startPressedHostTime: UInt64) async throws {
        let startedAt = SessionMetadata.now()
        let dir = try store.createSessionDirectory(startedAt: startedAt)
        directory = dir

        var meta = SessionMetadata.new(startedAt: startedAt, clock: clock)
        meta.startPressedHostTime = HostInstant(ticks: startPressedHostTime, clock: clock)
        for source in sources {
            let track = TrackMetadata(file: "\(source.name).caf", sampleRate: source.nominalSampleRate,
                                      channels: source.nominalChannels, deviceName: source.deviceName)
            if source.name == "system" { meta.system = track } else { meta.mic = track }
            writers[source.name] = TrackWriter(url: dir.appendingPathComponent(track.file), name: source.name,
                                               clock: clock) { [weak self] message in
                self?.addError(source: source.name, message: message)
            }
        }
        lock.withLock {
            base = meta
            periods = [(startPressedHostTime, nil)]
        }
        try store.write(meta, to: dir)
        log.info("Сессия \(dir.lastPathComponent, privacy: .public): старт")
        startTimer()

        let firstStartError = await startSources()

        // Имя устройства источник может узнать только при старте (дисплей ScreenCaptureKit)
        lock.withLock {
            for source in sources {
                if source.name == "system" { base?.system?.deviceName = source.deviceName }
                else { base?.mic?.deviceName = source.deviceName }
            }
        }

        if let firstStartError {
            _ = await finish(status: .failed)
            throw firstStartError
        }
    }

    /// Останавливает захват, закрывает файлы и пишет итоговый session.json.
    public func stop() async -> SessionMetadata {
        await finish(status: .completed)
    }

    public var isPaused: Bool {
        lock.withLock { periods.last?.end != nil }
    }

    /// Пауза (FR-14): захват останавливается, файлы остаются открытыми.
    /// pressedHostTime — момент нажатия «Пауза», конец текущего отрезка.
    public func pause(pressedHostTime: UInt64) async {
        guard !isPaused else { return }
        for source in sources { await source.stop() }
        for writer in writers.values { writer.pause() }
        lock.withLock { periods[periods.count - 1].end = pressedHostTime }
        log.info("Сессия \(self.directory?.lastPathComponent ?? "-", privacy: .public): пауза")
        if let meta = currentMetadata() { flush(meta) }
    }

    /// Возобновление: новый отрезок, первый буфер каждой дорожки дополняется тишиной
    /// на длину паузы, чтобы номер кадра остался привязан ко времени.
    public func resume(pressedHostTime: UInt64) async throws {
        guard isPaused else { return }
        for writer in writers.values { writer.resume() }
        lock.withLock { periods.append((pressedHostTime, nil)) }
        log.info("Сессия \(self.directory?.lastPathComponent ?? "-", privacy: .public): продолжение")
        if let error = await startSources() {
            for source in sources { await source.stop() }
            for writer in writers.values { writer.pause() }
            lock.withLock { periods[periods.count - 1].end = pressedHostTime }
            throw error
        }
    }

    /// Текущие метаданные с живыми счётчиками дорожек (для UI).
    public func currentMetadata() -> SessionMetadata? {
        compose(states: writers.mapValues { $0.snapshot() })
    }

    /// Флаг «несколько голосов в комнате» (E4, ADR-004 решение 3): попадает в session.json
    /// при следующей записи метаданных, разметка тогда размечает и mic.
    public func setMultipleVoices(_ on: Bool) {
        lock.withLock { base?.multipleVoices = on ? true : nil }
    }

    /// «Не удалять аудио этой записи» (FR-13, ADR-006 решение 7): пишется в session.json при остановке.
    public func setKeepAudio(_ on: Bool) {
        lock.withLock { base?.keepAudio = on }
    }

    public func addError(source: String, message: String) {
        log.error("[\(source, privacy: .public)] \(message, privacy: .public)")
        lock.withLock { base?.errors.append(SessionErrorRecord(source: source, message: message)) }
    }

    // MARK: Внутреннее

    /// Запускает все источники; возвращает первую ошибку старта.
    private func startSources() async -> Error? {
        var firstStartError: Error?
        await withTaskGroup(of: (String, Error?).self) { group in
            for source in sources {
                let writer = writers[source.name]!
                group.addTask { [weak self] in
                    do {
                        try await source.start(
                            onBuffer: { buffer, hostTime in writer.append(buffer, hostTime: hostTime) },
                            onFailure: { message in self?.addError(source: source.name, message: message) })
                        return (source.name, nil)
                    } catch {
                        return (source.name, error)
                    }
                }
            }
            for await (name, error) in group {
                guard let error else { continue }
                addError(source: name, message: "не удалось запустить захват: \(error.localizedDescription)")
                firstStartError = firstStartError ?? error
            }
        }
        return firstStartError
    }

    private func finish(status: SessionStatus) async -> SessionMetadata {
        timer?.cancel()
        timer = nil
        for source in sources { await source.stop() }
        let states = writers.mapValues { $0.finish() }
        let stopTicks = clock.now()
        lock.withLock {
            if !periods.isEmpty, periods[periods.count - 1].end == nil {
                periods[periods.count - 1].end = stopTicks
            }
        }

        if status == .completed {
            for source in sources where (states[source.name]?.framesWritten ?? 0) == 0 {
                addError(source: source.name, message: "дорожка \(source.name): нет данных за всю запись")
            }
        }
        lock.withLock {
            base?.status = status
            base?.stoppedAt = SessionMetadata.now()
        }
        let meta = compose(states: states)!
        flush(meta)
        log.info("Сессия \(self.directory?.lastPathComponent ?? "-", privacy: .public): \(status.rawValue, privacy: .public)")
        return meta
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + metadataInterval, repeating: metadataInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let meta = self.currentMetadata() else { return }
            self.flush(meta)
        }
        self.timer = timer
        timer.resume()
    }

    /// Снимки писателей берутся до lock: писатель сообщает об ошибках через addError,
    /// и ожидание его очереди под lock могло бы дать взаимную блокировку.
    private func compose(states: [String: TrackWriterState]) -> SessionMetadata? {
        lock.withLock {
            guard var meta = base else { return nil }
            meta.system = Self.merge(meta.system, states["system"])
            meta.mic = Self.merge(meta.mic, states["mic"])
            meta.segments = periods.enumerated().map { i, p in
                RecordingSegment(index: i,
                                 startHostTime: HostInstant(ticks: p.start, clock: clock),
                                 endHostTime: p.end.map { HostInstant(ticks: $0, clock: clock) },
                                 system: Self.frames(states["system"], i),
                                 mic: Self.frames(states["mic"], i))
            }
            meta.updatedAt = SessionMetadata.now()
            meta.refreshDerived(clock: clock)
            return meta
        }
    }

    private static func frames(_ state: TrackWriterState?, _ index: Int) -> FrameRange? {
        guard let state, index < state.segments.count else { return nil }
        return state.segments[index]
    }

    private static func merge(_ track: TrackMetadata?, _ state: TrackWriterState?) -> TrackMetadata? {
        guard var track, let state else { return track }
        if let rate = state.sampleRate { track.sampleRate = rate }
        if let channels = state.channels { track.channels = channels }
        track.firstSampleHostTime = state.firstSampleHostTime
        track.framesWritten = state.framesWritten
        track.durationSeconds = state.durationSeconds
        track.gaps = state.gaps
        track.anchors = state.anchors
        return track
    }

    private func flush(_ meta: SessionMetadata) {
        guard let directory else { return }
        do {
            try store.write(meta, to: directory)
            lock.withLock { flushFailed = false }
        } catch {
            // В сам session.json эту ошибку не записать; запоминаем её, чтобы она
            // попала в файл при следующей удачной записи.
            let first = lock.withLock { () -> Bool in
                defer { flushFailed = true }
                return !flushFailed
            }
            if first {
                addError(source: "session", message: "не удалось записать session.json: \(error.localizedDescription)")
            }
        }
    }
}
