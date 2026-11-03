import Foundation

/// Дорожка, из которой получена реплика (ADR-004, раздел 6).
public enum TranscriptTrack: String, Codable, Sendable, CaseIterable {
    case system, mic
}

/// Реплика: модель из ADR-004, раздел 6. Время в мс от alignment.originHostTime.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var track: TranscriptTrack
    /// "me" для mic (с флагом multipleVoices: "me" или "speaker-N"); "speaker-N" для system
    /// после разметки (E4); nil до разметки или если рядом нет ни одного хода говорящего.
    public var speakerId: String?
    public var startMs: Int
    public var endMs: Int
    public var text: String
    /// ru | en | other.
    public var language: String
    /// exp(средний logprob текстовых токенов), 0..1.
    public var confidence: Double
    /// Пересекающиеся реплики других говорящих (ADR-004 решение 5), заполняет разметка (E4).
    public var overlapWith: [String]
    public var modelVersion: String

    public init(id: String, sessionId: String, track: TranscriptTrack, speakerId: String?, startMs: Int, endMs: Int,
                text: String, language: String, confidence: Double, overlapWith: [String] = [], modelVersion: String) {
        self.id = id
        self.sessionId = sessionId
        self.track = track
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.language = language
        self.confidence = confidence
        self.overlapWith = overlapWith
        self.modelVersion = modelVersion
    }
}

public struct TranscriptSpeaker: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    /// «Я», «Собеседник 1»…
    public var label: String
    /// Имя, которое задал пользователь. Переименование меняет только это поле.
    public var displayName: String?

    public static let meId = "me"
}

/// Чанк расшифровки: отрезок дорожки в кадрах 16 кГц (время дорожки, без lead).
public struct TranscriptChunk: Codable, Equatable, Sendable {
    public var track: TranscriptTrack
    public var index: Int
    public var startSample: Int
    public var endSample: Int
    public var done: Bool

    public init(track: TranscriptTrack, index: Int, startSample: Int, endSample: Int, done: Bool = false) {
        self.track = track
        self.index = index
        self.startSample = startSample
        self.endSample = endSample
        self.done = done
    }

    public var sampleCount: Int { endSample - startSample }
}

/// Сведения о разметке говорящих в transcript.json (E4).
public struct TranscriptDiarization: Codable, Equatable, Sendable {
    public var modelVersion: String
    public var micDiarized: Bool
    public var createdAt: Date

    public init(modelVersion: String, micDiarized: Bool, createdAt: Date) {
        self.modelVersion = modelVersion
        self.micDiarized = micDiarized
        self.createdAt = createdAt
    }
}

/// Содержимое transcript.json (ADR-004, решение 20).
public struct Transcript: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sessionId: String
    public var modelVersion: String
    public var language: String
    /// system расшифрован по отрезкам речи (true) или целиком (false), ADR-004 решение 22.
    public var systemVAD: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var chunks: [TranscriptChunk]
    /// Отсортированы по startMs.
    public var segments: [TranscriptSegment]
    public var speakers: [TranscriptSpeaker]
    /// nil до разметки говорящих (E4). Новая расшифровка сбрасывает разметку.
    public var diarization: TranscriptDiarization? = nil

    public static let currentSchemaVersion = 1
    public static let fileName = "transcript.json"

    public var isComplete: Bool { !chunks.isEmpty && chunks.allSatisfy(\.done) }
}
