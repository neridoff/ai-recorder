import Foundation
import os

/// Ход расшифровки для UI и CLI.
public struct TranscriptionProgress: Sendable {
    public var fraction: Double
    public var chunksDone: Int
    public var chunksTotal: Int
    public var track: TranscriptTrack?
}

/// Расшифровка одной сессии (ADR-004, решения 13–21): system целиком, mic по VAD,
/// чанки по 5 минут, transcript.json после каждого чанка, статус в session.json,
/// возобновление с последнего готового чанка.
public final class TranscriptionJob {
    public static let lockFileName = SessionLock.fileName

    public let directory: URL
    private let engine: TranscriptionEngine
    private let language: String
    private let systemVAD: Bool
    private let clock: HostClock
    private let loadAudio: (URL) throws -> [Float]
    private let align: (URL) throws -> Void
    private let store: SessionStore
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "transcription")

    /// systemVAD: system тоже только по отрезкам речи, без порога громкости (по умолчанию,
    /// ADR-004 решение 22); false — system целиком, для сравнения.
    /// loadAudio и align подменяются в тестах; по умолчанию файл дорожки и сведение E2.
    public init(directory: URL, engine: TranscriptionEngine, language: String = "ru",
                systemVAD: Bool = true, clock: HostClock = .system,
                loadAudio: @escaping (URL) throws -> [Float] = TrackAudioLoader.loadMono16k(url:),
                align: @escaping (URL) throws -> Void = { _ = try SessionAlignment.run(sessionDirectory: $0) }) {
        self.directory = directory
        self.engine = engine
        self.language = language
        self.systemVAD = systemVAD
        self.clock = clock
        self.loadAudio = loadAudio
        self.align = align
        self.store = SessionStore(root: directory.deletingLastPathComponent())
    }

    private var transcriptURL: URL { directory.appendingPathComponent(Transcript.fileName) }
    private var sessionId: String { directory.lastPathComponent }

    @discardableResult
    public func run(restart: Bool = false,
                    progress: @escaping (TranscriptionProgress) -> Void = { _ in },
                    isCancelled: @escaping () -> Bool = { false }) throws -> Transcript {
        let lock = SessionLock(directory: directory)
        try lock.acquire()
        defer { lock.release() }

        var meta = try store.read(from: directory)
        guard meta.status != .recording else { throw TranscriptionError.stillRecording }
        if meta.alignment == nil {
            log.notice("\(self.sessionId, privacy: .public): нет alignment, сначала сведение")
            try align(directory)
            meta = try store.read(from: directory)
        }
        guard let alignment = meta.alignment else {
            throw TranscriptionError.engine("сведение не записало alignment в session.json")
        }

        let started = Date()
        var transcript = restart ? nil : loadCompatibleTranscript()
        let previousProcessing = transcript == nil ? 0 : (meta.transcription?.processingSeconds ?? 0)
        let fresh = transcript == nil
        if fresh {
            transcript = Transcript(schemaVersion: Transcript.currentSchemaVersion, sessionId: sessionId,
                                    modelVersion: engine.modelVersion, language: language,
                                    systemVAD: systemVAD, createdAt: SessionMetadata.now(), updatedAt: SessionMetadata.now(),
                                    chunks: [], segments: [], speakers: [])
        }
        var record = TranscriptionRecord(
            status: .running, progress: 0, chunksDone: 0, chunksTotal: 0, startedAt: SessionMetadata.now(),
            finishedAt: nil, audioSeconds: 0, micSpeechSeconds: meta.transcription?.micSpeechSeconds,
            processingSeconds: previousProcessing, realtimeFactor: nil, modelVersion: engine.modelVersion,
            transcriptFile: Transcript.fileName, error: nil)

        let tracks: [(TranscriptTrack, TrackMetadata, Double)] = [
            meta.system.map { (.system, $0, alignment.systemLeadMs) },
            meta.mic.map { (.mic, $0, alignment.micLeadMs) },
        ].compactMap { $0 }
        // Вес трека для прогресса до того, как он нарезан на чанки: длительность без пауз
        let plannedSeconds = Dictionary(uniqueKeysWithValues: tracks.map { track, info, _ in
            (track, activeSeconds(info, track: track, meta: meta))
        })

        func publish(_ t: Transcript, current: TranscriptTrack?, partial: Double = 0) {
            var total = 0.0, done = 0.0
            for (track, _, _) in tracks {
                let chunks = t.chunks.filter { $0.track == track }
                if chunks.isEmpty {
                    // ещё не нарезан или (mic) в нём нет речи; после mic других дорожек нет
                    total += track.order > (current?.order ?? Int.max) || current == track
                        ? (plannedSeconds[track] ?? 0) * Double(ChunkPlanner.sampleRate) : 0
                } else {
                    total += chunks.reduce(0) { $0 + Double($1.sampleCount) }
                    done += chunks.filter(\.done).reduce(0) { $0 + Double($1.sampleCount) }
                }
            }
            done += partial
            let fraction = total > 0 ? min(1, done / total) : 1
            record.progress = fraction
            record.chunksDone = t.chunks.filter(\.done).count
            record.chunksTotal = t.chunks.count
            progress(TranscriptionProgress(fraction: fraction, chunksDone: record.chunksDone,
                                           chunksTotal: record.chunksTotal, track: current))
        }

        do {
            try writeRecord(record, clearDiarization: fresh)
            for (track, info, leadMs) in tracks {
                if transcript!.chunks.contains(where: { $0.track == track }),
                   transcript!.chunks.filter({ $0.track == track }).allSatisfy(\.done) {
                    continue
                }
                if isCancelled() { throw TranscriptionError.cancelled }
                var samples = try loadAudio(directory.appendingPathComponent(info.file))
                // Отрезки речи: окна расшифровки. nil — дорожка расшифровывается целиком.
                var speech: [SpeechSpan]?
                if track == .mic {
                    speech = try maskNonSpeech(&samples)
                    record.micSpeechSeconds = speech!.reduce(0) { $0 + Double($1.durationMs) } / 1000
                } else if systemVAD {
                    speech = try detectSpans(samples)
                }
                if !transcript!.chunks.contains(where: { $0.track == track }) {
                    let chunks = speech?.isEmpty == true
                        ? []
                        : ChunkPlanner.plan(track: track, totalSamples: samples.count,
                                            excluded: excludedRanges(info, track: track, meta: meta,
                                                                     totalSamples: samples.count),
                                            windowEnergy: ChunkPlanner.windowEnergy(of: samples))
                    transcript!.chunks.append(contentsOf: chunks)
                    try save(&transcript!)
                }
                for i in transcript!.chunks.indices where transcript!.chunks[i].track == track && !transcript!.chunks[i].done {
                    if isCancelled() { throw TranscriptionError.cancelled }
                    let chunk = transcript!.chunks[i]
                    let perMs = ChunkPlanner.sampleRate / 1000
                    let chunkMs = chunk.startSample / perMs ..< chunk.endSample / perMs
                    let windows = speech.map { SpeechWindows.plan($0, within: chunkMs) } ?? [chunkMs]
                    let windowTotal = Double(windows.reduce(0) { $0 + $1.count })
                    var windowDone = 0.0
                    var result: [EngineSegment] = []
                    let snapshot = transcript!
                    for window in windows {
                        if isCancelled() { throw TranscriptionError.cancelled }
                        let a = min(window.lowerBound * perMs, samples.count)
                        let b = min(window.upperBound * perMs, samples.count)
                        let request = EngineRequest(samples: Array(samples[a ..< b]), language: language)
                        let done = windowDone
                        let segments = try engine.transcribe(request, progress: { p in
                            let fraction = (done + p * Double(window.count)) / max(windowTotal, 1)
                            publish(snapshot, current: track, partial: fraction * Double(chunk.sampleCount))
                        }, isCancelled: isCancelled)
                        // время окна → время от начала чанка
                        let shift = window.lowerBound - chunkMs.lowerBound
                        result += segments.map {
                            EngineSegment(startMs: $0.startMs + shift, endMs: min($0.endMs, window.count) + shift,
                                          text: $0.text, confidence: $0.confidence)
                        }
                        windowDone += Double(window.count)
                    }
                    transcript!.segments.append(contentsOf: SegmentMapping.map(
                        result, chunk: chunk, leadMs: leadMs, sessionId: sessionId,
                        modelVersion: engine.modelVersion, language: language))
                    transcript!.chunks[i].done = true
                    try save(&transcript!)
                    record.processingSeconds = previousProcessing + Date().timeIntervalSince(started)
                    publish(transcript!, current: track)
                    try writeRecord(record)
                }
            }
        } catch {
            record.status = .failed
            record.error = error.localizedDescription
            record.processingSeconds = previousProcessing + Date().timeIntervalSince(started)
            log.error("\(self.sessionId, privacy: .public): расшифровка прервана: \(error.localizedDescription, privacy: .public)")
            try? writeRecord(record)
            throw error
        }

        record.status = .done
        record.finishedAt = SessionMetadata.now()
        record.processingSeconds = previousProcessing + Date().timeIntervalSince(started)
        record.audioSeconds = transcript!.chunks.reduce(0) { $0 + Double($1.sampleCount) } / Double(ChunkPlanner.sampleRate)
        record.realtimeFactor = record.processingSeconds > 0 ? record.audioSeconds / record.processingSeconds : nil
        publish(transcript!, current: nil)
        try writeRecord(record)
        log.notice("\(self.sessionId, privacy: .public): расшифровано \(String(format: "%.0f", record.audioSeconds), privacy: .public) с звука за \(String(format: "%.1f", record.processingSeconds), privacy: .public) с, реплик \(transcript!.segments.count)")
        return transcript!
    }

    // MARK: Звук

    /// Обнуляет mic вне отрезков речи (VAD + порог громкости). Возвращает оставленные отрезки.
    private func maskNonSpeech(_ samples: inout [Float]) throws -> [SpeechSpan] {
        let perMs = ChunkPlanner.sampleRate / 1000
        let spans = try detectSpans(samples)
        let kept = SpeechGate.filter(spans).sorted { $0.startMs < $1.startMs }
        var pos = 0
        for s in kept {
            let a = min(max(s.startMs * perMs, pos), samples.count)
            let b = min(max(s.endMs * perMs, a), samples.count)
            samples.withUnsafeMutableBufferPointer { buf in
                for i in pos..<a { buf[i] = 0 }
            }
            pos = b
        }
        samples.withUnsafeMutableBufferPointer { buf in
            for i in pos..<buf.count { buf[i] = 0 }
        }
        log.notice("\(self.sessionId, privacy: .public): mic: VAD нашёл \(spans.count) отрезков, после порога громкости \(kept.count)")
        return kept
    }

    /// Отрезки речи по VAD с уровнем RMS.
    private func detectSpans(_ samples: [Float]) throws -> [SpeechSpan] {
        let perMs = ChunkPlanner.sampleRate / 1000
        return try engine.detectSpeech(samples).map { s -> SpeechSpan in
            let a = min(max(s.startMs * perMs, 0), samples.count)
            let b = min(max(s.endMs * perMs, a), samples.count)
            var sum = 0.0
            for i in a..<b { sum += Double(samples[i] * samples[i]) }
            let rms = b > a ? sum / Double(b - a) : 0
            return SpeechSpan(startMs: s.startMs, endMs: s.endMs, rmsDb: 10 * log10(rms + 1e-12))
        }
    }

    /// Паузы записи (между отрезками segments[]) в сэмплах 16 кГц.
    private func excludedRanges(_ info: TrackMetadata, track: TranscriptTrack, meta: SessionMetadata,
                                totalSamples: Int) -> [Range<Int>] {
        guard let segments = meta.segments, !segments.isEmpty else { return [] }
        let toSamples = { (frame: Int64) in Int((Double(frame) * Double(ChunkPlanner.sampleRate) / info.sampleRate).rounded()) }
        var excluded: [Range<Int>] = []
        var pos = 0
        for seg in segments.sorted(by: { $0.index < $1.index }) {
            guard let frames = track == .system ? seg.system : seg.mic else { continue }
            let start = toSamples(frames.startFrame), end = toSamples(frames.endFrame)
            if start > pos { excluded.append(pos ..< start) }
            pos = max(pos, end)
        }
        if totalSamples > pos { excluded.append(pos ..< totalSamples) }
        return excluded
    }

    private func activeSeconds(_ info: TrackMetadata, track: TranscriptTrack, meta: SessionMetadata) -> Double {
        guard let segments = meta.segments, !segments.isEmpty else { return info.durationSeconds }
        let frames = segments.compactMap { track == .system ? $0.system : $0.mic }
            .reduce(Int64(0)) { $0 + $1.endFrame - $1.startFrame }
        return Double(frames) / info.sampleRate
    }

    // MARK: Файлы

    private func loadCompatibleTranscript() -> Transcript? {
        guard let data = try? Data(contentsOf: transcriptURL),
              let t = try? SessionMetadata.decoder.decode(Transcript.self, from: data),
              t.schemaVersion == Transcript.currentSchemaVersion,
              t.modelVersion == engine.modelVersion,
              t.language == language,
              t.systemVAD == systemVAD else { return nil }
        return t
    }

    private func save(_ t: inout Transcript) throws {
        t.updatedAt = SessionMetadata.now()
        t.segments.sort { ($0.startMs, $0.track.order, $0.id) < ($1.startMs, $1.track.order, $1.id) }
        t.speakers = t.chunks.contains { $0.track == .mic }
            ? [TranscriptSpeaker(id: TranscriptSpeaker.meId, sessionId: sessionId, label: "Я", displayName: nil)]
            : []
        let data = try SessionMetadata.encoder.encode(t)
        try data.write(to: transcriptURL, options: .atomic)
    }

    /// Перечитывает session.json перед записью, чтобы не затереть чужие поля.
    /// clearDiarization: расшифровка начата заново, прежняя разметка говорящих больше не верна.
    private func writeRecord(_ record: TranscriptionRecord, clearDiarization: Bool = false) throws {
        var meta = try store.read(from: directory)
        meta.transcription = record
        if clearDiarization { meta.diarization = nil }
        meta.schemaVersion = max(meta.schemaVersion, SessionMetadata.currentSchemaVersion)
        meta.updatedAt = SessionMetadata.now()
        try store.write(meta, to: directory)
    }
}

extension TranscriptTrack {
    /// Порядок обработки и сортировки: system, затем mic.
    var order: Int { self == .system ? 0 : 1 }
}
