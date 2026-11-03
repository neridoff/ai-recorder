import XCTest
@testable import RecorderCore

final class SessionStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testCreatesDirectoryNamedByLocalStartTime() throws {
        let store = SessionStore(root: root)

        let dir = try store.createSessionDirectory(startedAt: localDate(2026, 11, 3, 10, 32, 7))

        XCTAssertEqual(dir.lastPathComponent, "Встреча 03.11.2026 10-32")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testSecondAndThirdSessionInSameMinuteGetSuffix() throws {
        let store = SessionStore(root: root)

        _ = try store.createSessionDirectory(startedAt: localDate(2026, 11, 3, 10, 32, 7))
        let second = try store.createSessionDirectory(startedAt: localDate(2026, 11, 3, 10, 32, 40))
        let third = try store.createSessionDirectory(startedAt: localDate(2026, 11, 3, 10, 32, 59))

        XCTAssertEqual(second.lastPathComponent, "Встреча 03.11.2026 10-32 (2)")
        XCTAssertEqual(third.lastPathComponent, "Встреча 03.11.2026 10-32 (3)")
    }

    func testDisplayTitleUsesColonForOldAndNewFolders() throws {
        let store = SessionStore(root: root)
        let started = localDate(2026, 11, 3, 10, 57, 32)
        let old = root.appendingPathComponent("2026-11-03_10-57-32")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try store.write(SessionMetadata.new(startedAt: started), to: old)
        let new = try store.createSessionDirectory(startedAt: started)
        try store.write(SessionMetadata.new(startedAt: started), to: new)

        XCTAssertEqual(store.displayTitle(of: old), "Встреча 03.11.2026 10:57")
        XCTAssertEqual(store.displayTitle(of: new), "Встреча 03.11.2026 10:57")
        XCTAssertEqual(store.displayTitle(of: root.appendingPathComponent("нет")), "нет", "без session.json — имя папки")
    }

    func testWritesAndReadsMetadata() throws {
        let store = SessionStore(root: root)
        let dir = try store.createSessionDirectory(startedAt: Date())
        var meta = SessionMetadata.new(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        meta.errors.append(SessionErrorRecord(at: Date(timeIntervalSince1970: 1_800_000_001), source: "mic", message: "boom"))

        try store.write(meta, to: dir)
        let read = try store.read(from: dir)

        XCTAssertEqual(read, meta)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path))
    }

    func testListsOnlyDirectoriesWithSessionJSONSortedByStartedAt() throws {
        let store = SessionStore(root: root)
        let b = try store.createSessionDirectory(startedAt: localDate(2026, 10, 28, 10, 0, 0))
        let a = try store.createSessionDirectory(startedAt: localDate(2026, 10, 27, 10, 0, 0))
        _ = try store.createSessionDirectory(startedAt: localDate(2026, 10, 29, 10, 0, 0))   // без session.json
        try store.write(SessionMetadata.new(startedAt: localDate(2026, 10, 28, 10, 0, 0)), to: b)
        try store.write(SessionMetadata.new(startedAt: localDate(2026, 10, 27, 10, 0, 0)), to: a)

        XCTAssertEqual(try store.sessionDirectories().map(\.lastPathComponent), ["Встреча 27.10.2026 10-00", "Встреча 28.10.2026 10-00"])
    }

    /// Смешанный архив: старые имена по дате, новые «Встреча дд.мм.гггг»; по имени порядок был бы неверный.
    func testMixedArchiveIsOrderedByStartedAtNotByName() throws {
        let store = SessionStore(root: root)
        let old1 = root.appendingPathComponent("2026-11-02_18-02-38")
        let old2 = root.appendingPathComponent("2026-11-03_10-57-32")
        for (dir, date) in [(old1, localDate(2026, 11, 2, 18, 2, 38)), (old2, localDate(2026, 11, 3, 10, 57, 32))] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try store.write(SessionMetadata.new(startedAt: date), to: dir)
        }
        // «Встреча 01.12…» по имени раньше «Встреча 04.11…», по времени — позже
        let dec = try store.createSessionDirectory(startedAt: localDate(2026, 12, 1, 9, 0, 0))
        try store.write(SessionMetadata.new(startedAt: localDate(2026, 12, 1, 9, 0, 0)), to: dec)
        let nov = try store.createSessionDirectory(startedAt: localDate(2026, 11, 4, 9, 0, 0))
        try store.write(SessionMetadata.new(startedAt: localDate(2026, 11, 4, 9, 0, 0)), to: nov)

        let names = try store.sessionDirectories().map(\.lastPathComponent)

        XCTAssertEqual(names, ["2026-11-02_18-02-38", "2026-11-03_10-57-32", "Встреча 04.11.2026 09-00", "Встреча 01.12.2026 09-00"])
        // «последняя запись» CLI и меню — sessionDirectories().last
        XCTAssertEqual(try store.sessionDirectories().last?.lastPathComponent, "Встреча 01.12.2026 09-00")
    }

    func testUnreadableSessionJsonFallsBackToFolderCreationDate() throws {
        let store = SessionStore(root: root)
        let good = try store.createSessionDirectory(startedAt: localDate(2001, 1, 1, 0, 0, 0))
        try store.write(SessionMetadata.new(startedAt: localDate(2001, 1, 1, 0, 0, 0)), to: good)
        let broken = root.appendingPathComponent("сломанная")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.metadataURL(in: broken))

        XCTAssertEqual(try store.sessionDirectories().map(\.lastPathComponent), [good.lastPathComponent, "сломанная"])
    }

    func testMoveToTrashOnlyAcceptsRecordingFoldersOfThisArchive() throws {
        let store = SessionStore(root: root)
        let dir = try store.createSessionDirectory(startedAt: localDate(2026, 11, 3, 13, 0, 0))
        try store.write(SessionMetadata.new(startedAt: Date()), to: dir)
        let empty = try store.createSessionDirectory(startedAt: localDate(2026, 11, 3, 14, 0, 0))   // без session.json
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try store.write(SessionMetadata.new(startedAt: Date()), to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        var trashed: [URL] = []
        let fake: (URL) throws -> Void = { trashed.append($0) }

        try store.moveToTrash(dir, trash: fake)
        for bad: URL in [empty, outside, root!] {
            XCTAssertThrowsError(try store.moveToTrash(bad, trash: fake), bad.path)
        }

        XCTAssertEqual(trashed, [dir])
    }

    func testListingMissingRootReturnsEmpty() throws {
        XCTAssertEqual(try SessionStore(root: root).sessionDirectories(), [])
    }
}
