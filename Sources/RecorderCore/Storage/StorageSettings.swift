import Foundation

/// Настройки приложения (E5.1, ADR-006 решение 9) поверх UserDefaults, домен com.neridov.airecorder.
/// Аргументы запуска (`-compressedAudioRetentionDays 1`) попадают в тот же UserDefaults на один
/// запуск и не сохраняются. Значение вне допустимого списка читается как значение по умолчанию.
public struct StorageSettings {
    public static let compressedDaysKey = "compressedAudioRetentionDays"
    public static let rawDaysKey = "rawAudioRetentionDays"
    public static let recordingsRootKey = "recordingsRoot"
    public static let autoProcessKey = "autoProcessOnStop"
    public static let notifyKey = "notifyOnDone"
    public static let languageKey = "transcriptionLanguage"
    public static let policyStartedKey = "retentionPolicyStartedAt"

    /// Сроки хранения в сутках; -1 — не удалять.
    public static let allowedDays = [1, 3, 7, 14, 30, 90, keepForever]
    public static let keepForever = -1
    public static let defaultDays = 7
    public static let languages = ["ru", "auto"]

    public let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Срок сжатого аудио обработанных записей, от compression.finishedAt (решение 3).
    public var compressedAudioRetentionDays: Int {
        get { days(Self.compressedDaysKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.compressedDaysKey) }
    }

    /// Срок сырого аудио записей без результата, от startedAt (решение 4).
    public var rawAudioRetentionDays: Int {
        get { days(Self.rawDaysKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.rawDaysKey) }
    }

    /// Папка архива; применяется после перезапуска приложения.
    public var recordingsRoot: URL {
        guard let path = defaults.string(forKey: Self.recordingsRootKey)?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else { return SessionStore.defaultRoot }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public func setRecordingsRoot(_ url: URL?) {
        if let url { defaults.set(url.path, forKey: Self.recordingsRootKey) } else { defaults.removeObject(forKey: Self.recordingsRootKey) }
    }

    public var autoProcessOnStop: Bool {
        get { bool(Self.autoProcessKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoProcessKey) }
    }

    public var notifyOnDone: Bool {
        get { bool(Self.notifyKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.notifyKey) }
    }

    /// Язык для whisper.cpp: `ru` или `auto` (определить по звуку).
    public var transcriptionLanguage: String {
        get {
            let value = defaults.string(forKey: Self.languageKey) ?? "ru"
            return Self.languages.contains(value) ? value : "ru"
        }
        nonmutating set { defaults.set(newValue, forKey: Self.languageKey) }
    }

    /// Дата перехода на сроки E5.1 (решение 10): записи до неё автоудалению не подлежат.
    /// Для проверок на копии архива: `-retentionPolicyStartedAt 2020-01-01T00:00:00Z` (строка ISO 8601).
    public var retentionPolicyStartedAt: Date? {
        switch defaults.object(forKey: Self.policyStartedKey) {
        case let date as Date: return date
        case let text as String: return ISO8601DateFormatter().date(from: text)
        default: return nil
        }
    }

    /// При первом запуске сборки E5.1 пишет дату перехода; если она уже есть, возвращает её.
    @discardableResult
    public func ensureRetentionPolicyStarted(now: Date = Date()) -> Date {
        if let date = retentionPolicyStartedAt { return date }
        defaults.set(now, forKey: Self.policyStartedKey)
        return now
    }

    public var retentionPolicy: AudioRetention.Policy {
        AudioRetention.Policy(compressedDays: compressedAudioRetentionDays, rawDays: rawAudioRetentionDays,
                              startedAt: retentionPolicyStartedAt)
    }

    /// `defaults write -int` даёт число, аргумент запуска строку; непонятная строка — значение по умолчанию.
    private func days(_ key: String) -> Int {
        let value: Int?
        switch defaults.object(forKey: key) {
        case let number as NSNumber: value = number.intValue
        case let text as String: value = Int(text.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        guard let value, Self.allowedDays.contains(value) else { return Self.defaultDays }
        return value
    }

    private func bool(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}
