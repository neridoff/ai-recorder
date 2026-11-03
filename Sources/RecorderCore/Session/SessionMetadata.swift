import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case recording, completed, recovered, failed
}

public struct HostTimebase: Codable, Equatable, Sendable {
    public var numer: UInt32
    public var denom: UInt32
}

public struct SessionErrorRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var source: String
    public var message: String

    public init(at: Date = SessionMetadata.now(), source: String, message: String) {
        self.at = at
        self.source = source
        self.message = message
    }
}

public struct TrackMetadata: Codable, Equatable, Sendable {
    public var file: String
    public var sampleRate: Double
    public var channels: Int
    public var deviceName: String
    public var firstSampleHostTime: HostInstant?
    public var framesWritten: Int64 = 0
    public var durationSeconds: Double = 0
    /// От нажатия «Старт» до первого сэмпла (FR-01: не больше 2000 мс).
    public var startLatencyMs: Double?
    public var gaps: [TrackGap] = []
    public var anchors: [TrackAnchor] = []

    public init(file: String, sampleRate: Double, channels: Int, deviceName: String) {
        self.file = file
        self.sampleRate = sampleRate
        self.channels = channels
        self.deviceName = deviceName
    }
}

/// Кадры дорожки внутри отрезка записи: [startFrame, endFrame).
public struct FrameRange: Codable, Equatable, Sendable {
    public var startFrame: Int64
    public var endFrame: Int64

    public init(startFrame: Int64, endFrame: Int64) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

/// Отрезок записи от «Старт» или «Продолжить» до «Пауза» или «Стоп» (FR-14, ADR-004 решение 14).
/// Между отрезками в дорожках лежит тишина длиной паузы.
public struct RecordingSegment: Codable, Equatable, Sendable {
    public var index: Int
    public var startHostTime: HostInstant
    public var endHostTime: HostInstant?
    public var system: FrameRange?
    public var mic: FrameRange?

    public init(index: Int, startHostTime: HostInstant, endHostTime: HostInstant? = nil,
                system: FrameRange? = nil, mic: FrameRange? = nil) {
        self.index = index
        self.startHostTime = startHostTime
        self.endHostTime = endHostTime
        self.system = system
        self.mic = mic
    }
}

public enum TranscriptionState: String, Codable, Sendable {
    case running, done, failed
}

/// Блок transcription в session.json (ADR-004, решение 18).
public struct TranscriptionRecord: Codable, Equatable, Sendable {
    public var status: TranscriptionState
    public var progress: Double
    public var chunksDone: Int
    public var chunksTotal: Int
    public var startedAt: Date
    public var finishedAt: Date?
    /// Звук, отданный Whisper: system целиком и mic по времени дорожки, без пауз, с.
    public var audioSeconds: Double
    /// Речь mic после VAD и порога громкости, с.
    public var micSpeechSeconds: Double?
    /// Время обработки, с; при возобновлении складывается.
    public var processingSeconds: Double
    /// audioSeconds / processingSeconds.
    public var realtimeFactor: Double?
    public var modelVersion: String
    public var transcriptFile: String
    public var error: String?
}

/// Блок diarization в session.json (E4, ADR-004 решения 8, 26).
public struct DiarizationRecord: Codable, Equatable, Sendable {
    public var status: TranscriptionState
    public var progress: Double
    public var startedAt: Date
    public var finishedAt: Date?
    /// Размеченный звук: system и, с флагом multipleVoices, mic, по времени дорожки, с.
    public var audioSeconds: Double
    public var processingSeconds: Double
    /// audioSeconds / processingSeconds.
    public var realtimeFactor: Double?
    /// Модели и порог кластеризации.
    public var modelVersion: String
    /// Собеседников (кластеров), которым досталась хотя бы одна реплика.
    public var speakers: Int
    /// mic тоже размечен (флаг «несколько голосов в комнате»).
    public var micDiarized: Bool
    public var error: String?
}

/// Почему удалено аудио: `retention` — сжатое по сроку, `rawExpired` — сырое записи без результата.
public enum AudioDeletedReason: String, Codable, Sendable {
    case retention, rawExpired
}

/// Содержимое session.json.
public struct SessionMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var appVersion: String
    public var osVersion: String
    public var pid: Int32
    public var startedAt: Date
    public var stoppedAt: Date?
    public var updatedAt: Date
    public var status: SessionStatus
    public var hostTimebase: HostTimebase
    public var startPressedHostTime: HostInstant?
    /// mic − system по первым сэмплам, мс. Положительное: микрофон стартовал позже.
    public var startOffsetMs: Double?
    public var system: TrackMetadata?
    public var mic: TrackMetadata?
    public var errors: [SessionErrorRecord] = []
    /// Результат сведения и замера дрейфа (E2, mix-session). Появился в схеме 2.
    public var alignment: AlignmentRecord?
    /// Отрезки записи между паузами (FR-14, схема 3). Пусто в записях до схемы 3:
    /// тогда вся запись считается одним отрезком.
    public var segments: [RecordingSegment]?
    /// Состояние расшифровки (E3, схема 3).
    public var transcription: TranscriptionRecord?
    /// Флаг «несколько голосов в комнате» (E4, ADR-004 решение 3): mic тоже размечается.
    /// nil = выключен.
    public var multipleVoices: Bool?
    /// Состояние разметки говорящих (E4, схема 4).
    public var diarization: DiarizationRecord?
    /// Сжатие дорожек после обработки (E5, ADR-005, схема 5).
    public var compression: CompressionRecord?
    /// «Не удалять аудио» (FR-13): ставится вручную в session.json. nil в записях до E5 = false.
    public var keepAudio: Bool?
    /// Аудио удалено по сроку хранения (FR-11): дорожки и mixed, текст и session.json остаются.
    public var audioDeleted: Bool?
    public var audioDeletedAt: Date?
    /// Какое аудио удалено по сроку (E5.1, ADR-006 решение 12, схема 6).
    public var audioDeletedReason: AudioDeletedReason?
    /// Когда отправлено предупреждение за сутки до удаления сырого аудио (ADR-006 решение 6).
    public var deletionWarnedAt: Date?

    /// 2: добавлено необязательное поле alignment. 3: segments и transcription.
    /// 4: multipleVoices и diarization. 5: compression, keepAudio, audioDeleted, audioDeletedAt.
    /// 6: audioDeletedReason, deletionWarnedAt. Файлы старых версий читаются как есть.
    public static let currentSchemaVersion = 6

    /// Обработка закончена: есть расшифровка и разметка (статус «готово»), запись не идёт.
    public var isProcessed: Bool {
        status != .recording && transcription?.status == .done && diarization?.status == .done
    }

    /// Настенное время для метаданных с точностью до секунды: ISO 8601 в session.json
    /// хранит целые секунды, и так данные в памяти совпадают с файлом.
    /// Точное время событий хранится в host time.
    public static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    public static func new(startedAt: Date, clock: HostClock = .system) -> SessionMetadata {
        SessionMetadata(
            schemaVersion: currentSchemaVersion,
            appVersion: appVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            stoppedAt: nil,
            updatedAt: startedAt,
            status: .recording,
            hostTimebase: HostTimebase(numer: clock.numer, denom: clock.denom),
            keepAudio: false)
    }

    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0-dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Пересчитывает производные поля: сдвиг старта и задержку старта по дорожкам.
    public mutating func refreshDerived(clock: HostClock = .system) {
        if let sys = system?.firstSampleHostTime, let m = mic?.firstSampleHostTime {
            startOffsetMs = clock.milliseconds(from: sys.ticks, to: m.ticks)
        } else {
            startOffsetMs = nil
        }
        if let pressed = startPressedHostTime {
            if let first = system?.firstSampleHostTime {
                system?.startLatencyMs = clock.milliseconds(from: pressed.ticks, to: first.ticks)
            }
            if let first = mic?.firstSampleHostTime {
                mic?.startLatencyMs = clock.milliseconds(from: pressed.ticks, to: first.ticks)
            }
        }
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
