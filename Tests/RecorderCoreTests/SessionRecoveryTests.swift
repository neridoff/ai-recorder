import XCTest
import AVFoundation
@testable import RecorderCore

final class SessionRecoveryTests: XCTestCase {
    var root: URL!
    var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Сессия «как после kill -9»: session.json со статусом recording и устаревшими
    /// счётчиками, CAF-файлы скопированы, пока AVAudioFile был открыт.
    private func makeCrashedSession(pid: Int32 = 999_999, systemFrames: AVAudioFrameCount = 48_000, micFrames: AVAudioFrameCount? = 24_000) throws -> URL {
        let dir = try store.createSessionDirectory(startedAt: Date())
        var meta = SessionMetadata.new(startedAt: Date())
        meta.pid = pid
        meta.system = TrackMetadata(file: "system.caf", sampleRate: 48_000, channels: 2, deviceName: "Display")
        meta.system?.framesWritten = 100     // снимок пятисекундной давности
        meta.mic = TrackMetadata(file: "mic.caf", sampleRate: 24_000, channels: 1, deviceName: "Mic")
        try store.write(meta, to: dir)

        try writeOpenCopy(to: dir.appendingPathComponent("system.caf"), rate: 48_000, channels: 2, frames: systemFrames)
        if let micFrames {
            try writeOpenCopy(to: dir.appendingPathComponent("mic.caf"), rate: 24_000, channels: 1, frames: micFrames)
        }
        return dir
    }

    private func writeOpenCopy(to url: URL, rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let live = url.deletingLastPathComponent().appendingPathComponent("live-\(url.lastPathComponent)")
        let file = try AVAudioFile(forWriting: live, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        try FileManager.default.copyItem(at: live, to: url)
        _ = file
        try FileManager.default.removeItem(at: live)
    }

    func testCrashedSessionIsMarkedRecoveredWithActualFrameCounts() throws {
        let dir = try makeCrashedSession()
        let recovery = SessionRecovery(store: store, isProcessAlive: { _ in false })

        let reports = recovery.recoverAll()

        XCTAssertEqual(reports.map(\.directory.lastPathComponent), [dir.lastPathComponent])
        let meta = try store.read(from: dir)
        XCTAssertEqual(meta.status, .recovered)
        XCTAssertEqual(meta.system?.framesWritten, 48_000)
        XCTAssertEqual(meta.system?.durationSeconds ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(meta.mic?.framesWritten, 24_000)
        XCTAssertNotNil(meta.stoppedAt)
        XCTAssertTrue(meta.errors.contains { $0.source == "recovery" })
        XCTAssertEqual(try AVAudioFile(forReading: dir.appendingPathComponent("system.caf")).length, 48_000)
    }

    func testCompletedSessionIsNotTouched() throws {
        let dir = try makeCrashedSession()
        var meta = try store.read(from: dir)
        meta.status = .completed
        try store.write(meta, to: dir)
        let before = try Data(contentsOf: store.metadataURL(in: dir))

        let reports = SessionRecovery(store: store, isProcessAlive: { _ in false }).recoverAll()

        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.metadataURL(in: dir)), before)
    }

    func testSessionOfLiveProcessIsSkipped() throws {
        let dir = try makeCrashedSession(pid: 4242)

        let reports = SessionRecovery(store: store, isProcessAlive: { $0 == 4242 }).recoverAll()

        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(try store.read(from: dir).status, .recording)
    }

    func testMissingTrackFileIsRecordedAsError() throws {
        let dir = try makeCrashedSession(micFrames: nil)

        _ = SessionRecovery(store: store, isProcessAlive: { _ in false }).recoverAll()

        let meta = try store.read(from: dir)
        XCTAssertEqual(meta.status, .recovered)
        XCTAssertTrue(meta.errors.contains { $0.message.contains("mic.caf") })
    }

    func testDefaultLivenessTreatsOwnPidAsDead() {
        // при запуске приложения своя сессия ещё не идёт, совпадение pid — переиспользование
        XCTAssertFalse(SessionRecovery.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(SessionRecovery.processIsAlive(1))   // launchd
    }
}
