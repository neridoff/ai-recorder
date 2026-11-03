import XCTest
@testable import RecorderCore

final class SessionMetadataTests: XCTestCase {
    let clock = HostClock(numer: 1000, denom: 1)   // 1 тик = 1 мкс

    private func track(file: String, firstTicks: UInt64?) -> TrackMetadata {
        var t = TrackMetadata(file: file, sampleRate: 48_000, channels: 2, deviceName: "Test")
        t.firstSampleHostTime = firstTicks.map { HostInstant(ticks: $0, clock: clock) }
        return t
    }

    func testStartOffsetIsMicMinusSystemWithSign() {
        var meta = SessionMetadata.new(startedAt: Date(), clock: clock)
        meta.system = track(file: "system.caf", firstTicks: 849_969_477_000)
        meta.mic = track(file: "mic.caf", firstTicks: 849_969_342_000)

        meta.refreshDerived(clock: clock)

        XCTAssertEqual(meta.startOffsetMs!, -135, accuracy: 1e-6)
    }

    func testStartOffsetIsNilUntilBothTracksHaveFirstSample() {
        var meta = SessionMetadata.new(startedAt: Date(), clock: clock)
        meta.system = track(file: "system.caf", firstTicks: 1_000)
        meta.mic = track(file: "mic.caf", firstTicks: nil)

        meta.refreshDerived(clock: clock)

        XCTAssertNil(meta.startOffsetMs)
    }

    func testStartLatencyIsMeasuredFromStartPress() {
        var meta = SessionMetadata.new(startedAt: Date(), clock: clock)
        meta.startPressedHostTime = HostInstant(ticks: 1_000_000, clock: clock)
        meta.system = track(file: "system.caf", firstTicks: 1_450_000)

        meta.refreshDerived(clock: clock)

        XCTAssertEqual(meta.system!.startLatencyMs!, 450, accuracy: 1e-6)
    }

    func testJSONUsesISO8601DatesAndRoundTrips() throws {
        var meta = SessionMetadata.new(startedAt: Date(timeIntervalSince1970: 1_800_000_000), clock: clock)
        meta.status = .completed
        meta.stoppedAt = Date(timeIntervalSince1970: 1_800_000_090)
        meta.system = track(file: "system.caf", firstTicks: 5)

        let data = try SessionMetadata.encoder.encode(meta)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try SessionMetadata.decoder.decode(SessionMetadata.self, from: data)

        XCTAssertTrue(json.contains("\"startedAt\" : \"2027-01-15T08:00:00Z\""), json)
        XCTAssertTrue(json.contains("\"status\" : \"completed\""))
        XCTAssertEqual(decoded, meta)
    }

    func testNewSessionCarriesSchemaVersionsTimebaseAndPid() {
        let meta = SessionMetadata.new(startedAt: Date(), clock: clock)

        XCTAssertEqual(meta.schemaVersion, SessionMetadata.currentSchemaVersion)
        XCTAssertEqual(meta.status, .recording)
        XCTAssertEqual(meta.hostTimebase, HostTimebase(numer: 1000, denom: 1))
        XCTAssertEqual(meta.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(meta.osVersion.isEmpty)
        XCTAssertFalse(meta.appVersion.isEmpty)
    }
}
