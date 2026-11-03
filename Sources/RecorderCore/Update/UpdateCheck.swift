import Foundation

/// Проверка обновлений по нажатию (FR-27, ADR-007): разбор ответа GitHub, сравнение версий,
/// команда обновления. Без ввода-вывода: запрос делает приложение (UpdateChecker).
public enum UpdateCheck {
    /// Репозиторий на GitHub (ADR-007 решение 2), https://github.com/neridoff/ai-recorder. Пустые значения:
    /// адрес не задан, проверка сразу заканчивается ошибкой без запроса.
    public static let owner = "neridoff"
    public static let repository = "ai-recorder"
    public static let timeout: TimeInterval = 10
    /// Номер найденной версии и страница релиза (решение 11), ключи UserDefaults.
    public static let availableVersionKey = "availableUpdateVersion"
    public static let availableURLKey = "availableUpdateURL"

    public struct Release: Equatable, Sendable {
        /// Тег без префикса «v», например «1.2.0».
        public let version: String
        /// Страница релиза; nil, если хост не github.com (решение 7).
        public let pageURL: URL?

        public init(version: String, pageURL: URL?) {
            self.version = version
            self.pageURL = pageURL
        }
    }

    public enum Outcome: Equatable, Sendable {
        case available(Release, installed: String)
        case upToDate(installed: String)
        case failed(String)
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON, missingTag, badVersion(String)

        public var description: String {
            switch self {
            case .notJSON: return "неожиданный ответ сервера"
            case .missingTag: return "в ответе нет номера версии"
            case .badVersion(let tag): return "непонятный номер версии «\(tag)»"
            }
        }
    }

    /// Адрес запроса или nil, если репозиторий не задан.
    public static func latestReleaseURL(owner: String = owner, repository: String = repository) -> URL? {
        guard !owner.isEmpty, !repository.isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")
    }

    /// Из ответа берутся только `tag_name` и `html_url` (решение 4).
    public static func parse(_ data: Data) throws -> Release {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        guard let tag = object["tag_name"] as? String, !tag.isEmpty else { throw ParseError.missingTag }
        let version = stripPrefix(tag)
        guard components(version) != nil else { throw ParseError.badVersion(tag) }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)).flatMap(safePage)
        return Release(version: version, pageURL: page)
    }

    /// Итог проверки по коду ответа и телу (решение 6).
    public static func outcome(status: Int, data: Data, installed: String) -> Outcome {
        guard status == 200 else {
            return .failed(status == 404 ? "релиз не найден (ответ 404)" : "ответ сервера \(status)")
        }
        do {
            let release = try parse(data)
            return isNewer(release.version, than: installed)
                ? .available(release, installed: installed) : .upToDate(installed: installed)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Числовые компоненты слева направо, недостающие равны 0: «1.2» == «1.2.0».
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let a = components(stripPrefix(candidate)), let b = components(stripPrefix(installed)) else {
            return false
        }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Только https://github.com/… (решение 7), остальное игнорируется.
    public static func safePage(_ url: URL) -> URL? {
        url.scheme == "https" && url.host?.lowercased() == "github.com" ? url : nil
    }

    /// Текст кнопки «Скопировать команду» (решение 12). `sourcePath` — содержимое source-path.
    /// Без пути возвращается подсказка «выполните в папке проекта».
    public static func updateCommand(sourcePath: String?) -> (command: String, hint: String?) {
        let path = sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return ("git pull && ./install.sh", "выполните в папке проекта") }
        let quoted = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return ("cd \"\(quoted)\" && git pull && ./install.sh", nil)
    }

    /// `~/Library/Application Support/AI Recorder/source-path`, его пишет install.sh.
    public static var sourcePathFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Recorder/source-path")
    }

    private static func stripPrefix(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        return numbers
    }
}
