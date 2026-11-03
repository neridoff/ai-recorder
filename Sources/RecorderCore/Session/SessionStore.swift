import Foundation

/// Папки сессий: <root>/<Встреча дд.мм.гггг чч-мм>/{system.caf, mic.caf, session.json};
/// в архиве до E5.1 — <YYYY-MM-DD_HH-mm-ss>.
public struct SessionStore: Sendable {
    public static let metadataFileName = "session.json"

    public let root: URL

    public init(root: URL = SessionStore.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("AI Recorder", isDirectory: true)
    }

    /// Папка новой записи: «Встреча дд.мм.гггг чч-мм» по местному времени начала (ADR-006 решение 17).
    /// Двоеточие в имени Finder показал бы как «/», поэтому время через дефис; секунды в session.json.
    /// Две записи в одну минуту: « (2)», « (3)».
    public func createSessionDirectory(startedAt: Date) throws -> URL {
        let base = Self.directoryName(startedAt: startedAt)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var name = base
        var suffix = 2
        while true {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            do {
                // без withIntermediateDirectories, чтобы существующая папка дала ошибку
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                return dir
            } catch CocoaError.fileWriteFileExists {
                name = "\(base) (\(suffix))"
                suffix += 1
            }
        }
    }

    public static func directoryName(startedAt: Date) -> String {
        "Встреча " + formatted(startedAt, "dd.MM.yyyy HH-mm")
    }

    /// Название записи для человека: «Встреча дд.мм.гггг чч:мм» (меню, уведомления, CLI, transcript.md).
    /// Для старых папок вида 2026-11-03_10-57-32 тоже строится из startedAt.
    public static func displayTitle(startedAt: Date) -> String {
        "Встреча " + formatted(startedAt, "dd.MM.yyyy HH:mm")
    }

    /// Название по session.json; если он не читается, имя папки.
    public func displayTitle(of dir: URL) -> String {
        (try? read(from: dir)).map { Self.displayTitle(startedAt: $0.startedAt) } ?? dir.lastPathComponent
    }

    static func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    public func metadataURL(in dir: URL) -> URL {
        dir.appendingPathComponent(Self.metadataFileName)
    }

    /// Атомарная запись: при сбое на диске остаётся прежняя целая версия.
    public func write(_ metadata: SessionMetadata, to dir: URL) throws {
        let data = try SessionMetadata.encoder.encode(metadata)
        try data.write(to: metadataURL(in: dir), options: .atomic)
    }

    public func read(from dir: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: metadataURL(in: dir))
        return try SessionMetadata.decoder.decode(SessionMetadata.self, from: data)
    }

    /// Чтение, правка и атомарная запись session.json одним шагом (флаги из меню).
    public func update(_ dir: URL, _ change: (inout SessionMetadata) -> Void) throws {
        var meta = try read(from: dir)
        change(&meta)
        try write(meta, to: dir)
    }

    /// Папки записей от старых к новым по startedAt из session.json (ADR-006 решение 17):
    /// новые имена «Встреча дд.мм.гггг чч-мм» по имени не сортируются. Папка без читаемого
    /// session.json встаёт по дате создания; при равном времени порядок по имени.
    public func sessionDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let fm = FileManager.default
        let dated: [(url: URL, date: Date)] = try fm
            .contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])
            .filter { fm.fileExists(atPath: metadataURL(in: $0).path) }
            .map { dir in
                let started = (try? Data(contentsOf: metadataURL(in: dir)))
                    .flatMap { try? SessionMetadata.decoder.decode(StartedAt.self, from: $0) }?.startedAt
                let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return (dir, started ?? created ?? .distantPast)
            }
        // адреса от root, а не из листинга (там /private/var вместо /var): так они совпадают
        // с папкой, которую вернул createSessionDirectory, и сравниваются в очереди и списке
        return dated.sorted { ($0.date, $0.url.lastPathComponent) < ($1.date, $1.url.lastPathComponent) }
            .map { root.appendingPathComponent($0.url.lastPathComponent, isDirectory: true) }
    }

    /// Перемещает папку записи в Корзину macOS (E5.1, «Удалить…» в списке записей без результата).
    /// Только папку записи этого архива: внутри root и с session.json. Вернуть можно из Корзины.
    public func moveToTrash(_ dir: URL,
                            trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let dirPath = dir.standardizedFileURL.resolvingSymlinksInPath().path
        guard dir.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == rootPath,
              dirPath != rootPath,
              FileManager.default.fileExists(atPath: metadataURL(in: dir).path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: dir.path])
        }
        try trash(dir)
    }

    /// Только startedAt: порядок архива не зависит от остальных полей и их версий.
    private struct StartedAt: Decodable { var startedAt: Date }
}
