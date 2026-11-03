import Foundation
import AVFoundation
import os

/// Разрыв в потоке: буфер пришёл не тогда, когда ожидался по числу записанных кадров.
/// durationMs > 0 — данных не хватило (дыра заполнена тишиной, filledFrames),
/// durationMs < 0 — буфер пришёл раньше ожидаемого (перекрытие, ничего не заполняем).
public struct TrackGap: Codable, Equatable, Sendable {
    public var atFrame: Int64
    public var hostTime: HostInstant
    public var durationMs: Double
    public var filledFrames: Int64
}

/// Опорная точка: какой кадр файла соответствует какому моменту host time.
/// Нужна в E2 для замера дрейфа между часами устройства и хоста.
public struct TrackAnchor: Codable, Equatable, Sendable {
    public var hostTime: HostInstant
    public var frame: Int64
}

/// Чистая логика времени дорожки: первый сэмпл, счёт кадров, разрывы, anchors.
/// Не делает ввод-вывод, поэтому тестируется без аудио.
public struct TrackTimeline: Sendable {
    public let sampleRate: Double
    public let clock: HostClock
    public let gapThresholdSeconds: Double
    public let anchorIntervalSeconds: Double
    public let maxFillSeconds: Double

    public private(set) var firstSampleHostTime: UInt64?
    public private(set) var framesWritten: Int64 = 0
    public private(set) var gaps: [TrackGap] = []
    public private(set) var anchors: [TrackAnchor] = []

    private var expectedNextSeconds: Double?
    private var nextAnchorFrame: Int64 = 0

    public init(sampleRate: Double,
                clock: HostClock = .system,
                gapThresholdSeconds: Double = 0.02,
                anchorIntervalSeconds: Double = 60,
                maxFillSeconds: Double = 300) {
        self.sampleRate = sampleRate
        self.clock = clock
        self.gapThresholdSeconds = gapThresholdSeconds
        self.anchorIntervalSeconds = anchorIntervalSeconds
        self.maxFillSeconds = maxFillSeconds
    }

    public var durationSeconds: Double { Double(framesWritten) / sampleRate }

    /// Учитывает буфер, пришедший с меткой hostTime (время его первого сэмпла).
    /// Возвращает число кадров тишины, которые нужно записать перед буфером.
    /// afterPause: первый буфер после паузы записи (FR-14). Пауза заполняется тишиной
    /// целиком, без предела maxFillSeconds, и не считается разрывом.
    public mutating func ingest(hostTime: UInt64, frameCount: Int, afterPause: Bool = false) -> Int {
        let actual = clock.seconds(hostTime)
        var silence: Int64 = 0

        if firstSampleHostTime == nil {
            firstSampleHostTime = hostTime
        } else if afterPause, let expected = expectedNextSeconds {
            silence = Int64((max(actual - expected, 0) * sampleRate).rounded())
            framesWritten += silence
        } else if let expected = expectedNextSeconds {
            let deviation = actual - expected
            if abs(deviation) > gapThresholdSeconds {
                if deviation > 0 {
                    silence = Int64((min(deviation, maxFillSeconds) * sampleRate).rounded())
                }
                gaps.append(TrackGap(atFrame: framesWritten,
                                     hostTime: HostInstant(ticks: hostTime, clock: clock),
                                     durationMs: deviation * 1000,
                                     filledFrames: silence))
                framesWritten += silence
            }
        }

        if framesWritten >= nextAnchorFrame {
            anchors.append(TrackAnchor(hostTime: HostInstant(ticks: hostTime, clock: clock), frame: framesWritten))
            let interval = Int64(anchorIntervalSeconds * sampleRate)
            nextAnchorFrame = (framesWritten / interval + 1) * interval
        }

        framesWritten += Int64(frameCount)
        expectedNextSeconds = actual + Double(frameCount) / sampleRate
        return Int(silence)
    }
}

// MARK: - TrackWriter

/// Состояние дорожки на момент снимка (для session.json).
public struct TrackWriterState: Sendable {
    public var sampleRate: Double?
    public var channels: Int?
    public var firstSampleHostTime: HostInstant?
    public var framesWritten: Int64 = 0
    public var durationSeconds: Double = 0
    public var gaps: [TrackGap] = []
    public var anchors: [TrackAnchor] = []
    /// Кадры каждого отрезка записи между паузами; nil, если в отрезке не было буферов.
    public var segments: [FrameRange?] = []
    public var errors: [String] = []
}

/// Пишет одну дорожку в CAF PCM. Вызывающий поток (аудиопоток или очередь
/// ScreenCaptureKit) только копирует буфер; файл, таймлайн и ошибки живут
/// на собственной последовательной очереди писателя.
/// Файл создаётся по формату первого буфера, без ресемплинга.
public final class TrackWriter: @unchecked Sendable {
    public let url: URL
    public let name: String

    private let clock: HostClock
    private let queue: DispatchQueue
    private let onError: (String) -> Void
    private let log: Logger

    // Всё ниже меняется только на queue
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var timeline: TrackTimeline?
    private var errors: [String] = []
    private var finished = false
    private var creationFailed = false
    private var droppedBuffers = 0
    /// Отрезки записи (FR-14): первый кадр отрезка ставится по первому буферу в нём.
    private var periods: [(start: Int64?, end: Int64?)] = [(nil, nil)]
    private var paused = false

    /// onError вызывается на очереди писателя, один раз на каждую новую ошибку.
    public init(url: URL, name: String, clock: HostClock = .system, onError: @escaping (String) -> Void = { _ in }) {
        self.url = url
        self.name = name
        self.clock = clock
        self.onError = onError
        self.queue = DispatchQueue(label: "airecorder.writer.\(name)", qos: .userInitiated)
        self.log = Logger(subsystem: RecorderLog.subsystem, category: "writer.\(name)")
    }

    /// hostTime — время первого сэмпла буфера в тиках mach_absolute_time.
    public func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let copy = Self.copy(buffer) else {
            queue.async { self.record("\(self.name): не удалось скопировать аудиобуфер") }
            return
        }
        queue.async { self.write(copy, hostTime: hostTime) }
    }

    /// Пауза записи: вызывается после остановки захвата, когда новых буферов нет.
    /// Закрывает текущий отрезок; буферы до resume() отбрасываются.
    public func pause() {
        queue.sync {
            guard !paused else { return }
            paused = true
            periods[periods.count - 1].end = timeline?.framesWritten
        }
    }

    /// Новый отрезок: первый буфер после паузы дополняется тишиной на её длину.
    public func resume() {
        queue.sync {
            guard paused else { return }
            paused = false
            periods.append((nil, nil))
        }
    }

    public func snapshot() -> TrackWriterState {
        queue.sync { state() }
    }

    /// Дописывает очередь, закрывает файл (AVAudioFile обновляет заголовок CAF) и
    /// возвращает итоговое состояние. Последующие append игнорируются.
    public func finish() -> TrackWriterState {
        queue.sync {
            finished = true
            file = nil
            if droppedBuffers > 0 {
                log.notice("\(self.name, privacy: .public): отброшено буферов после ошибки формата: \(self.droppedBuffers)")
            }
            return state()
        }
    }

    // MARK: Очередь писателя

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard !finished, !creationFailed, !paused else { return }

        if file == nil {
            do {
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat,
                                       interleaved: buffer.format.isInterleaved)
                format = buffer.format
                timeline = TrackTimeline(sampleRate: buffer.format.sampleRate, clock: clock)
                log.info("\(self.name, privacy: .public): файл создан, \(buffer.format.sampleRate) Гц, \(buffer.format.channelCount) кан.")
            } catch {
                creationFailed = true
                record("\(name): не удалось создать \(url.lastPathComponent): \(error.localizedDescription)")
                return
            }
        }

        guard let file, let format, buffer.format == format else {
            droppedBuffers += 1
            record("\(name): формат буфера изменился (\(Self.describe(self.format)) → \(Self.describe(buffer.format))), вероятно сменилось аудиоустройство; запись дорожки остановлена")
            return
        }

        let afterPause = periods.count > 1 && periods[periods.count - 1].start == nil
        let silence = timeline!.ingest(hostTime: hostTime, frameCount: Int(buffer.frameLength), afterPause: afterPause)
        if periods[periods.count - 1].start == nil {
            periods[periods.count - 1].start = timeline!.framesWritten - Int64(buffer.frameLength)
        }
        do {
            if silence > 0 {
                try writeSilence(frames: silence, to: file, format: format)
            }
            try file.write(from: buffer)
        } catch {
            record("\(name): ошибка записи в \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func writeSilence(frames: Int, to file: AVAudioFile, format: AVAudioFormat) throws {
        let chunk = AVAudioFrameCount(format.sampleRate)   // по секунде
        guard let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "не удалось выделить буфер тишины"])
        }
        zeros.frameLength = chunk
        for b in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
            if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
        }
        var left = frames
        while left > 0 {
            zeros.frameLength = AVAudioFrameCount(min(left, Int(chunk)))
            try file.write(from: zeros)
            left -= Int(zeros.frameLength)
        }
    }

    /// Ошибка уходит в лог и в список для session.json; повтор той же ошибки подряд не дублируется.
    private func record(_ message: String) {
        guard errors.last != message else { return }
        errors.append(message)
        log.error("\(message, privacy: .public)")
        onError(message)
    }

    private func state() -> TrackWriterState {
        var s = TrackWriterState()
        s.sampleRate = format?.sampleRate
        s.channels = format.map { Int($0.channelCount) }
        if let t = timeline {
            s.firstSampleHostTime = t.firstSampleHostTime.map { HostInstant(ticks: $0, clock: clock) }
            s.framesWritten = t.framesWritten
            s.durationSeconds = t.durationSeconds
            s.gaps = t.gaps
            s.anchors = t.anchors
        }
        s.segments = periods.map { p in
            p.start.map { FrameRange(startFrame: $0, endFrame: p.end ?? s.framesWritten) }
        }
        s.errors = errors
        return s
    }

    private static func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "нет" }
        return "\(Int(format.sampleRate)) Гц/\(format.channelCount) кан."
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let s = src[i].mData, let d = dst[i].mData else { return nil }
            let bytes = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
            memcpy(d, s, bytes)
        }
        return copy
    }
}
