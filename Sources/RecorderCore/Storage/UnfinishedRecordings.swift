import Foundation

/// Запись без результата для списка в меню (E5.1, ADR-006 решение 8): сырые дорожки на диске,
/// запись не идёт, успешного результата нет. Только чтение session.json, файлы не меняются.
public struct UnfinishedRecording: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case transcriptionFailed, diarizationFailed, cancelled, notStarted, recovered, emptyResult

        public var text: String {
            switch self {
            case .transcriptionFailed: return "ошибка расшифровки"
            case .diarizationFailed: return "ошибка разметки"
            case .cancelled: return "отменена"
            case .notStarted: return "не запускалась"
            case .recovered: return "восстановлена после сбоя"
            case .emptyResult: return "пустой результат"
            }
        }

        /// Повтор начинает расшифровку заново: продолжать нечего, прежний результат пустой.
        /// Остальные причины идут текущей логикой возобновления (готовые чанки не пересчитываются).
        public var restartsTranscription: Bool { self == .emptyResult }
    }

    /// Пометка для записи, которую приложение уже обрабатывает или поставило в очередь.
    public enum Activity: Equatable, Sendable {
        case idle, queued, processing
    }

    public var directory: URL
    public var startedAt: Date
    public var durationSeconds: Double
    public var reason: Reason
    /// Когда удалится сырое аудио; nil — «хранится» (keepAudio, срок «не удалять», запись до перехода).
    public var deletesAt: Date?
    public var keepAudio: Bool

    public var title: String { SessionStore.displayTitle(startedAt: startedAt) }

    /// Строка в меню: «ДД.ММ ЧЧ:ММ, N мин, <причина>, удалится ДД.ММ».
    public func row(activity: Activity = .idle) -> String {
        let minutes = Int((durationSeconds / 60).rounded())
        let state: String
        switch activity {
        case .idle: state = reason.text
        case .queued: state = "в очереди"
        case .processing: state = "в обработке"
        }
        let deletion = deletesAt.map { "удалится " + SessionStore.formatted($0, "dd.MM") } ?? "хранится"
        return "\(SessionStore.formatted(startedAt, "dd.MM HH:mm")), \(minutes < 1 && durationSeconds > 0 ? "<1" : "\(minutes)") мин, \(state), \(deletion)"
    }
}

public enum UnfinishedRecordings {
    /// Строк в меню; остальные — «Ещё N…».
    public static let menuLimit = 10

    /// Записи без результата, новые сверху. recording: папка идущей записи, она в список не входит.
    public static func scan(store: SessionStore, policy: AudioRetention.Policy, recording: URL? = nil) -> [UnfinishedRecording] {
        let skip = recording?.standardizedFileURL.path
        return ((try? store.sessionDirectories()) ?? []).reversed().compactMap { dir in
            guard dir.standardizedFileURL.path != skip, let meta = try? store.read(from: dir) else { return nil }
            return entry(dir, meta: meta, policy: policy)
        }
    }

    /// nil: запись идёт, аудио удалено или сырых дорожек нет, либо результат есть.
    public static func entry(_ dir: URL, meta: SessionMetadata, policy: AudioRetention.Policy) -> UnfinishedRecording? {
        guard meta.status != .recording, meta.audioDeleted != true else { return nil }
        let fm = FileManager.default
        let raw = [meta.system?.file, meta.mic?.file].compactMap { $0 }
            .filter { ($0 as NSString).pathExtension == "caf" && fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard !raw.isEmpty else { return nil }
        // запись только со сбоем сжатия не входит: результат есть, сжатие повторится само
        guard !AudioRetention.hasValidResult(in: dir, meta: meta) else { return nil }
        return UnfinishedRecording(directory: dir, startedAt: meta.startedAt,
                                   durationSeconds: meta.system?.durationSeconds ?? meta.mic?.durationSeconds ?? 0,
                                   reason: reason(dir, meta: meta),
                                   deletesAt: AudioRetention.rawExpiryDate(meta, policy: policy),
                                   keepAudio: meta.keepAudio == true)
    }

    static func reason(_ dir: URL, meta: SessionMetadata) -> UnfinishedRecording.Reason {
        let cancelled = [TranscriptionError.cancelled.localizedDescription, DiarizationError.cancelled.localizedDescription]
        guard let transcription = meta.transcription else {
            return meta.status == .recovered ? .recovered : .notStarted
        }
        switch transcription.status {
        case .failed:
            return cancelled.contains(transcription.error ?? "") ? .cancelled : .transcriptionFailed
        case .running:
            // running без живого процесса: приложение закрылось или упало посреди расшифровки
            return meta.status == .recovered ? .recovered : .transcriptionFailed
        case .done:
            break
        }
        if (AudioRetention.segmentCount(in: dir) ?? 0) == 0 { return .emptyResult }
        switch meta.diarization?.status {
        case .failed?:
            return cancelled.contains(meta.diarization?.error ?? "") ? .cancelled : .diarizationFailed
        case .running?, nil:
            return .diarizationFailed
        case .done?:
            return .emptyResult   // обработка готова, но transcript.md пустой или его нет
        }
    }

    /// «Повторить все»: доступные записи от старых к новым.
    public static func retryOrder(_ list: [UnfinishedRecording], activity: (URL) -> UnfinishedRecording.Activity) -> [URL] {
        list.filter { activity($0.directory) == .idle }.sorted { $0.startedAt < $1.startedAt }.map(\.directory)
    }
}
