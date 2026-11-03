import Foundation

/// Сегмент от движка: время в мс от начала переданного звука.
public struct EngineSegment: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var confidence: Double

    public init(startMs: Int, endMs: Int, text: String, confidence: Double) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
    }
}

public struct EngineRequest: Sendable {
    /// Моно 16 кГц.
    public var samples: [Float]
    /// "ru" или "auto".
    public var language: String

    public init(samples: [Float], language: String) {
        self.samples = samples
        self.language = language
    }
}

/// Распознавание речи. Реализация на whisper.cpp живёт в модуле WhisperEngine,
/// чтобы RecorderCore и его тесты не зависели от модели.
public protocol TranscriptionEngine: AnyObject {
    /// Попадает в modelVersion реплик и в transcript.json.
    var modelVersion: String { get }
    /// progress: доля 0..1 внутри запроса. isCancelled опрашивается во время работы.
    func transcribe(_ request: EngineRequest, progress: @escaping (Double) -> Void,
                    isCancelled: @escaping () -> Bool) throws -> [EngineSegment]
    /// Отрезки речи (VAD), мс от начала samples (моно 16 кГц).
    func detectSpeech(_ samples: [Float]) throws -> [(startMs: Int, endMs: Int)]
}

public enum TranscriptionError: LocalizedError, Equatable {
    case cancelled
    case modelMissing(String)
    case engine(String)
    case stillRecording
    case alreadyRunning(Int32)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "расшифровка отменена"
        case .modelMissing(let path): return "нет модели \(path); запустите scripts/fetch-models.sh"
        case .engine(let why): return "ошибка whisper: \(why)"
        case .stillRecording: return "сессия в статусе recording: запись идёт или ещё не восстановлена после сбоя"
        case .alreadyRunning(let pid): return "обработка этой сессии уже идёт (pid \(pid))"
        }
    }
}
