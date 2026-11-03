import Foundation

/// Автоудаление аудио по сроку хранения (FR-11, FR-13, ADR-005). Удаляются только звуковые
/// файлы записи: дорожки и mixed. transcript.json, transcript.md, session.json, Labels.txt,
/// reviewed.md и другие файлы пользователя остаются.
public enum AudioRetention {
    /// Новая отметка в transcript.md (ADR-006 решение 13) и отметка E5 в старых файлах.
    public static let markText = "Аудио удалено"
    static let legacyMarkText = "Аудио удалено по сроку хранения"

    /// Сроки из настроек и дата перехода (ADR-006 решения 3, 4, 10).
    public struct Policy: Equatable, Sendable {
        public var compressedDays: Int
        public var rawDays: Int
        /// Записи с startedAt раньше этой даты не удаляются; nil — защиты нет.
        public var startedAt: Date?

        public init(compressedDays: Int, rawDays: Int, startedAt: Date?) {
            self.compressedDays = compressedDays
            self.rawDays = rawDays
            self.startedAt = startedAt
        }
    }

    /// Какое аудио лежит у записи и по какому правилу оно удаляется.
    public enum AudioKind: Equatable, Sendable {
        /// Сжатая копия после успешной обработки: срок compressedDays от compression.finishedAt.
        case compressed
        /// Сырые дорожки записи без успешного результата или со сбоем сжатия: rawDays от startedAt.
        case raw
    }

    public enum KeepReason: Equatable, Sendable {
        case alreadyDeleted
        /// Запись идёт, стоит в очереди или обрабатывается.
        case active
        /// keepAudio: true в session.json (FR-13).
        case keepAudioFlag
        /// Запись сделана до перехода на сроки E5.1 (решение 10).
        case beforePolicy
        /// Результат есть, сжатие ещё не выполнялось: сначала оно, потом срок сжатой копии.
        case awaitingCompression
        /// Срок «не удалять» (-1).
        case keepForever
        case notExpired
    }

    public enum Decision: Equatable, Sendable {
        case delete(AudioKind)
        case keep(KeepReason)
    }

    /// hasResult: обработка успешна и результат прошёл проверку (`hasValidResult`).
    /// isActive: запись в очереди или в обработке у приложения.
    public static func decide(_ meta: SessionMetadata, hasResult: Bool, policy: Policy, now: Date,
                              isActive: Bool = false) -> Decision {
        if meta.audioDeleted == true { return .keep(.alreadyDeleted) }
        if meta.status == .recording || isActive { return .keep(.active) }
        if meta.keepAudio == true { return .keep(.keepAudioFlag) }
        if let start = policy.startedAt, meta.startedAt < start { return .keep(.beforePolicy) }
        guard let kind = kind(meta, hasResult: hasResult) else { return .keep(.awaitingCompression) }
        guard let expiry = expiryDate(meta, kind: kind, policy: policy) else { return .keep(.keepForever) }
        return now >= expiry ? .delete(kind) : .keep(.notExpired)
    }

    /// nil: результат есть, а сжатие ещё не пробовали.
    public static func kind(_ meta: SessionMetadata, hasResult: Bool) -> AudioKind? {
        if meta.compression?.status == .done { return .compressed }
        if hasResult && meta.compression == nil { return nil }
        return .raw
    }

    /// Когда аудио удалится по сроку; nil — срок «не удалять».
    public static func expiryDate(_ meta: SessionMetadata, kind: AudioKind, policy: Policy) -> Date? {
        let (days, from): (Int, Date) = kind == .compressed
            ? (policy.compressedDays, meta.compression?.finishedAt ?? meta.startedAt)
            : (policy.rawDays, meta.startedAt)
        guard days != StorageSettings.keepForever else { return nil }
        return from.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// Дата удаления сырого аудио записи без результата для списка в меню; nil — «хранится»
    /// (keepAudio, срок «не удалять», запись до перехода).
    public static func rawExpiryDate(_ meta: SessionMetadata, policy: Policy) -> Date? {
        if meta.keepAudio == true { return nil }
        if let start = policy.startedAt, meta.startedAt < start { return nil }
        return expiryDate(meta, kind: .raw, policy: policy)
    }

    /// Проверка результата перед сжатием (ADR-006 решение 1): расшифровка и разметка готовы,
    /// transcript.json и transcript.md есть и не пустые, реплик не меньше одной.
    public static func hasValidResult(in dir: URL, meta: SessionMetadata) -> Bool {
        guard meta.isProcessed else { return false }
        return (segmentCount(in: dir) ?? 0) > 0
            && AudioCompression.fileSize(dir.appendingPathComponent(TranscriptMarkdown.fileName)) > 0
    }

    /// Реплик в transcript.json; nil — файла нет, он пустой или не читается.
    public static func segmentCount(in dir: URL) -> Int? {
        let url = dir.appendingPathComponent(Transcript.fileName)
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let transcript = try? SessionMetadata.decoder.decode(Transcript.self, from: data) else { return nil }
        return transcript.segments.count
    }

    /// Удаляет звуковые файлы записи (сжатые или сырые), ставит audioDeleted, audioDeletedAt,
    /// audioDeletedReason и отметку в transcript.md, если он есть.
    /// Сначала файлы, потом session.json: после сбоя посередине удаление просто повторится.
    @discardableResult
    public static func deleteAudio(in dir: URL, store: SessionStore, reason: AudioDeletedReason = .retention,
                                   now: Date = SessionMetadata.now()) throws -> [String] {
        let lock = SessionLock(directory: dir)
        try lock.acquire()
        defer { lock.release() }

        var meta = try store.read(from: dir)
        var names = [meta.system?.file, meta.mic?.file, meta.alignment?.mixFile].compactMap { $0 }
        names += (meta.compression?.tracks.map(\.originalFile) ?? [])
        names += MixFormat.allCases.map { SessionAlignment.mixFileName($0) }
        let fm = FileManager.default
        // временные файлы сжатия и сведения: .system.partial.m4a, .mixed.partial.m4a
        names += ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".") && $0.contains(".partial.") }
        var removed: [String] = []
        for name in names where !removed.contains(name) {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
            removed.append(name)
        }
        meta.audioDeleted = true
        meta.audioDeletedAt = now
        meta.audioDeletedReason = reason
        AudioCompression.stamp(&meta, now: now)
        try store.write(meta, to: dir)
        let md = dir.appendingPathComponent(TranscriptMarkdown.fileName)
        if let text = try? String(contentsOf: md, encoding: .utf8) {
            try Data(TranscriptMarkdown.markAudioDeleted(text, at: now).utf8).write(to: md, options: .atomic)
        }
        return removed.filter { !$0.hasPrefix(".") }
    }

    /// Дата в отметке: ДД.ММ.ГГГГ по местному времени.
    public static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: date)
    }
}

/// Обслуживание архива (E5, E5.1): сжатие записей с успешным результатом, удаление аудио по срокам,
/// предупреждение за сутки до удаления сырого аудио. Приложение запускает его при старте, раз в сутки
/// и после обработки, когда нет записи и обработки (R-03).
public enum StorageMaintenance {
    public struct Report: Equatable, Sendable {
        public var compressed: [String] = []
        public var audioDeleted: [String] = []
        /// Сжатие не выполнено: результат пустой или не прошёл проверку (ADR-006 решение 1).
        public var emptyResults: [String] = []
        /// Записи, по которым отправлено предупреждение за сутки.
        public var warned: [String] = []
        public var failures: [String] = []
        public var cancelled = false
        /// Байт освобождено сжатием (до минус после).
        public var savedBytes: Int64 = 0
    }

    /// До удаления сырого аудио осталось не больше этого: предупреждение (решение 6).
    public static let warningInterval: TimeInterval = 86_400

    /// warn: локальное уведомление о скором удалении; после него в session.json пишется deletionWarnedAt.
    /// active: папки в очереди или в обработке у приложения.
    public static func run(store: SessionStore, policy: AudioRetention.Policy, now: Date = SessionMetadata.now(),
                           active: Set<URL> = [],
                           warn: (URL, SessionMetadata, Date) -> Void = { _, _, _ in },
                           isCancelled: @escaping () -> Bool = { false }) -> Report {
        var report = Report()
        let dirs: [URL]
        do {
            dirs = try store.sessionDirectories()
        } catch {
            report.failures.append("архив: \(error.localizedDescription)")
            return report
        }
        let activePaths = Set(active.map(\.standardizedFileURL.path))
        for dir in dirs {
            if isCancelled() { report.cancelled = true; break }
            let name = dir.lastPathComponent
            guard var meta = try? store.read(from: dir) else { continue }
            let isActive = activePaths.contains(dir.standardizedFileURL.path)
            var hasResult = meta.isProcessed && AudioRetention.hasValidResult(in: dir, meta: meta)
            if AudioCompression.needsCompression(meta), !isActive {
                if hasResult {
                    do {
                        let record = try AudioCompression.compress(directory: dir, store: store, now: now, isCancelled: isCancelled)
                        if record.status == .done {
                            report.compressed.append(name)
                            report.savedBytes += record.tracks.reduce(0) { $0 + $1.originalBytes - $1.bytes }
                        } else {
                            report.failures.append("\(name): сжатие: \(record.error ?? "")")
                        }
                    } catch AudioStorageError.cancelled {
                        report.cancelled = true
                        break
                    } catch {
                        report.failures.append("\(name): сжатие: \(error.localizedDescription)")
                        continue
                    }
                    guard let fresh = try? store.read(from: dir) else { continue }
                    meta = fresh
                } else {
                    report.emptyResults.append(name)   // сырые остаются, запись в списке «без результата»
                }
            } else {
                AudioCompression.removeLeftoverOriginals(in: dir, meta: meta)
            }
            hasResult = hasResult || meta.compression?.status == .done
            switch AudioRetention.decide(meta, hasResult: hasResult, policy: policy, now: now, isActive: isActive) {
            case .delete(let kind):
                do {
                    try AudioRetention.deleteAudio(in: dir, store: store, reason: kind == .compressed ? .retention : .rawExpired, now: now)
                    report.audioDeleted.append(name)
                } catch {
                    report.failures.append("\(name): удаление аудио: \(error.localizedDescription)")
                }
            case .keep(.notExpired) where AudioRetention.kind(meta, hasResult: hasResult) == .raw && !hasResult:
                guard let expiry = AudioRetention.expiryDate(meta, kind: .raw, policy: policy),
                      expiry.timeIntervalSince(now) <= warningInterval else { continue }
                // одно предупреждение на срок; если срок потом продлили, предупреждение придёт снова
                if let warned = meta.deletionWarnedAt, warned >= expiry.addingTimeInterval(-warningInterval) { continue }
                warn(dir, meta, expiry)
                do {
                    try store.update(dir) {
                        $0.deletionWarnedAt = now
                        AudioCompression.stamp(&$0, now: now)
                    }
                    report.warned.append(name)
                } catch {
                    report.failures.append("\(name): deletionWarnedAt: \(error.localizedDescription)")
                }
            default:
                continue
            }
        }
        return report
    }

    /// Сколько записей потеряют аудио при таких сроках прямо сейчас (диалог в окне настроек, решение 11).
    public static func countDeletions(store: SessionStore, policy: AudioRetention.Policy, now: Date = Date(),
                                      active: Set<URL> = []) -> Int {
        let activePaths = Set(active.map(\.standardizedFileURL.path))
        return ((try? store.sessionDirectories()) ?? []).filter { dir in
            guard let meta = try? store.read(from: dir) else { return false }
            let hasResult = meta.compression?.status == .done || AudioRetention.hasValidResult(in: dir, meta: meta)
            if case .delete = AudioRetention.decide(meta, hasResult: hasResult, policy: policy, now: now,
                                                     isActive: activePaths.contains(dir.standardizedFileURL.path)) {
                return true
            }
            return false
        }.count
    }
}
