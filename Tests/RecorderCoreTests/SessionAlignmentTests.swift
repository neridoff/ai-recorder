import XCTest
import AVFoundation
@testable import RecorderCore

final class SessionAlignmentTests: XCTestCase {
    var root: URL!
    var dir: URL!
    let clock = HostClock(numer: 1000, denom: 1)   // 1 тик = 1 мкс

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dir = root.appendingPathComponent("2026-10-28_10-00-00")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSilence(_ name: String, rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) { memset(buffer.floatChannelData![ch], 0, Int(frames) * 4) }
        try file.write(from: buffer)
    }

    /// Сессия на 30 с: anchors на 0 и 20 с, микрофон на 5 ppm быстрее номинала.
    private func makeSession(status: SessionStatus) throws -> SessionMetadata {
        try writeSilence("system.caf", rate: 48_000, channels: 2, frames: 1_440_000)
        try writeSilence("mic.caf", rate: 48_000, channels: 1, frames: 1_440_000)
        var meta = SessionMetadata.new(startedAt: Date(timeIntervalSince1970: 1_800_000_000), clock: clock)
        meta.status = status
        func track(_ file: String, channels: Int, first: Double, actualRate: Double) -> TrackMetadata {
            var t = TrackMetadata(file: file, sampleRate: 48_000, channels: channels, deviceName: "Test")
            t.firstSampleHostTime = HostInstant(ticks: clock.ticks(seconds: first), clock: clock)
            t.framesWritten = 1_440_000
            t.durationSeconds = 30
            t.anchors = [0, 960_000].map { frame in
                TrackAnchor(hostTime: HostInstant(ticks: clock.ticks(seconds: first + Double(frame) / actualRate), clock: clock),
                            frame: frame)
            }
            return t
        }
        meta.system = track("system.caf", channels: 2, first: 500.08, actualRate: 48_000)
        meta.mic = track("mic.caf", channels: 1, first: 500.0, actualRate: 48_000 * (1 + 5e-6))
        meta.refreshDerived(clock: clock)
        try SessionStore(root: root).write(meta, to: dir)
        return meta
    }

    func testAlignmentIsWrittenToSessionJsonWithSchemaVersion2() throws {
        // запись ранней версии E1: схема 1, alignment поднимает её до 2
        var old = try makeSession(status: .completed)
        old.schemaVersion = 1
        try SessionStore(root: root).write(old, to: dir)

        let record = try SessionAlignment.run(sessionDirectory: dir, format: .caf, now: Date(timeIntervalSince1970: 1_800_000_100))

        let saved = try SessionStore(root: root).read(from: dir)
        XCTAssertEqual(saved.schemaVersion, 2)
        XCTAssertEqual(saved.alignment, record)
        XCTAssertEqual(record.mixFile, "mixed.caf")
        XCTAssertEqual(record.startOffsetMs!, -80, accuracy: 1e-3)
        XCTAssertEqual(record.systemLeadMs, 80, accuracy: 0.03)
        XCTAssertEqual(record.micLeadMs, 0)
        XCTAssertEqual(record.drift.relativePpm!, 5, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mixed.caf").path))
    }

    func testRecordingSessionIsRefused() throws {
        _ = try makeSession(status: .recording)

        XCTAssertThrowsError(try SessionAlignment.run(sessionDirectory: dir, format: .caf)) { error in
            XCTAssertEqual(error as? SessionAlignment.Failure, .stillRecording)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mixed.caf").path))
    }

    func testDryRunDoesNotTouchSessionJson() throws {
        _ = try makeSession(status: .completed)
        let before = try Data(contentsOf: dir.appendingPathComponent("session.json"))

        _ = try SessionAlignment.run(sessionDirectory: dir, format: .caf, writeMetadata: false)

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("session.json")), before)
    }

    func testSchemaVersion1JsonStillDecodes() throws {
        let meta = try makeSession(status: .completed)
        var json = try JSONSerialization.jsonObject(with: SessionMetadata.encoder.encode(meta)) as! [String: Any]
        json["schemaVersion"] = 1
        json.removeValue(forKey: "alignment")

        let decoded = try SessionMetadata.decoder.decode(SessionMetadata.self,
                                                         from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.alignment)
    }
}
