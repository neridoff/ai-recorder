import Foundation
import os

/// Разметка говорящих. Реализация на sherpa-onnx живёт в модуле SherpaEngine,
/// чтобы RecorderCore и его тесты не зависели от моделей.
public protocol SpeakerDiarizer: AnyObject {
    /// Модели и порог кластеризации; попадает в transcript.json и session.json.
    var modelVersion: String { get }
    /// samples: моно 16 кГц. Ходы в мс от начала samples. progress: доля 0..1.
    func diarize(_ samples: [Float], progress: @escaping (Double) -> Void) throws -> [SpeakerTurn]
}

public enum DiarizationError: LocalizedError, Equatable {
    case noTranscript
    case cancelled
    case modelMissing(String)
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .noTranscript: return "нет готовой расшифровки: сначала расшифруйте запись"
        case .cancelled: return "разметка отменена"
        case .modelMissing(let path): return "нет модели \(path); запустите scripts/fetch-models.sh"
        case .engine(let why): return "ошибка sherpa-onnx: \(why)"
        }
    }
}

/// Этап «Разметка» (E4, ADR-004 решения 3, 5, 6, 8): после расшифровки размечает system
/// (и mic с флагом «несколько голосов в комнате»), пишет speakerId, overlapWith и speakers[]
/// в transcript.json и блок diarization в session.json. Каждый запуск размечает заново.
public final class DiarizationJob {
    public let directory: URL
    private let diarizer: SpeakerDiarizer
    private let multipleVoices: Bool?
    private let loadAudio: (URL) throws -> [Float]
    private let store: SessionStore
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "diarization")

    /// multipleVoices: nil — флаг из session.json; true/false — переопределить (CLI).
    public init(directory: URL, diarizer: SpeakerDiarizer, multipleVoices: Bool? = nil,
                loadAudio: @escaping (URL) throws -> [Float] = TrackAudioLoader.loadMono16k(url:)) {
        self.directory = directory
        self.diarizer = diarizer
        self.multipleVoices = multipleVoices
        self.loadAudio = loadAudio
        self.store = SessionStore(root: directory.deletingLastPathComponent())
    }

    private var transcriptURL: URL { directory.appendingPathComponent(Transcript.fileName) }
    private var sessionId: String { directory.lastPathComponent }

    @discardableResult
    public func run(progress: @escaping (Double) -> Void = { _ in },
                    isCancelled: @escaping () -> Bool = { false }) throws -> Transcript {
        let lock = SessionLock(directory: directory)
        try lock.acquire()
        defer { lock.release() }

        let meta = try store.read(from: directory)
        guard meta.status != .recording else { throw TranscriptionError.stillRecording }
        let micDiarized = multipleVoices ?? meta.multipleVoices ?? false
        let started = Date()
        var record = DiarizationRecord(status: .running, progress: 0, startedAt: SessionMetadata.now(), finishedAt: nil,
                                       audioSeconds: 0, processingSeconds: 0, realtimeFactor: nil,
                                       modelVersion: diarizer.modelVersion, speakers: 0, micDiarized: micDiarized,
                                       error: nil)
        do {
            try writeRecord(record)
            guard let data = try? Data(contentsOf: transcriptURL),
                  var transcript = try? SessionMetadata.decoder.decode(Transcript.self, from: data),
                  transcript.isComplete,
                  let alignment = meta.alignment else { throw DiarizationError.noTranscript }

            var tracks: [(TrackMetadata, Double)] = []
            if let system = meta.system { tracks.append((system, alignment.systemLeadMs)) }
            if micDiarized, let mic = meta.mic { tracks.append((mic, alignment.micLeadMs)) }
            let weights = tracks.map { max($0.0.durationSeconds, 1) }
            let totalWeight = weights.reduce(0, +)

            var turns: [[SpeakerTurn]] = []
            var doneWeight = 0.0
            for (i, (info, leadMs)) in tracks.enumerated() {
                if isCancelled() { throw DiarizationError.cancelled }
                let samples = try loadAudio(directory.appendingPathComponent(info.file))
                record.audioSeconds += Double(samples.count) / TrackAudioLoader.sampleRate
                let base = doneWeight
                let raw = try diarizer.diarize(samples) { p in
                    progress(min(1, (base + p * weights[i]) / totalWeight))
                }
                let lead = Int(leadMs.rounded())
                turns.append(raw.map { SpeakerTurn(startMs: $0.startMs + lead, endMs: $0.endMs + lead, speaker: $0.speaker) })
                doneWeight += weights[i]
                log.notice("\(self.sessionId, privacy: .public): \(info.file, privacy: .public): ходов \(raw.count), кластеров \(Set(raw.map(\.speaker)).count)")
            }
            if isCancelled() { throw DiarizationError.cancelled }

            let result = SpeakerAttribution.apply(segments: transcript.segments, sessionId: sessionId,
                                                  systemTurns: turns.first ?? [],
                                                  micTurns: micDiarized ? (turns.count > 1 ? turns[1] : []) : nil)
            transcript.segments = result.segments
            transcript.speakers = result.speakers
            transcript.diarization = TranscriptDiarization(modelVersion: diarizer.modelVersion,
                                                           micDiarized: micDiarized, createdAt: SessionMetadata.now())
            transcript.updatedAt = SessionMetadata.now()
            try SessionMetadata.encoder.encode(transcript).write(to: transcriptURL, options: .atomic)

            record.status = .done
            record.progress = 1
            record.finishedAt = SessionMetadata.now()
            record.processingSeconds = Date().timeIntervalSince(started)
            record.realtimeFactor = record.processingSeconds > 0 ? record.audioSeconds / record.processingSeconds : nil
            record.speakers = result.speakers.filter { $0.id != TranscriptSpeaker.meId }.count
            try writeRecord(record)
            progress(1)
            log.notice("\(self.sessionId, privacy: .public): разметка готова за \(String(format: "%.1f", record.processingSeconds), privacy: .public) с, собеседников \(record.speakers)")
            return transcript
        } catch {
            record.status = .failed
            record.error = error.localizedDescription
            record.processingSeconds = Date().timeIntervalSince(started)
            log.error("\(self.sessionId, privacy: .public): разметка прервана: \(error.localizedDescription, privacy: .public)")
            try? writeRecord(record)
            throw error
        }
    }

    /// Перечитывает session.json перед записью, чтобы не затереть чужие поля.
    private func writeRecord(_ record: DiarizationRecord) throws {
        var meta = try store.read(from: directory)
        meta.diarization = record
        meta.schemaVersion = max(meta.schemaVersion, SessionMetadata.currentSchemaVersion)
        meta.updatedAt = SessionMetadata.now()
        try store.write(meta, to: directory)
    }
}
