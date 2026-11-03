import XCTest
@testable import RecorderCore

final class DriftAnalysisTests: XCTestCase {
    let clock = HostClock(numer: 1000, denom: 1)   // 1 тик = 1 мкс

    /// Anchors раз в 60 с по кадрам; host time идёт с заданной фактической частотой.
    private func anchors(count: Int, nominal: Double, actual: Double, startSeconds: Double = 1000) -> [TrackAnchor] {
        (0..<count).map { i in
            let frame = Int64(i) * Int64(60 * nominal)
            let seconds = startSeconds + Double(frame) / actual
            return TrackAnchor(hostTime: HostInstant(ticks: clock.ticks(seconds: seconds), clock: clock), frame: frame)
        }
    }

    func testNominalRateGivesZeroPpm() {
        let drift = TrackDrift.measure(anchors: anchors(count: 5, nominal: 48_000, actual: 48_000),
                                       nominalRate: 48_000, clock: clock)!

        XCTAssertEqual(drift.ppm, 0, accuracy: 0.05)
        XCTAssertEqual(drift.measuredRate, 48_000, accuracy: 0.01)
        XCTAssertEqual(drift.anchorCount, 5)
        XCTAssertEqual(drift.spanSeconds, 240, accuracy: 1e-3)
    }

    func testFasterDeviceGivesPositivePpm() {
        // устройство выдаёт на 10 ppm больше кадров в секунду host time
        let actual = 48_000 * (1 + 10e-6)
        let drift = TrackDrift.measure(anchors: anchors(count: 31, nominal: 48_000, actual: actual),
                                       nominalRate: 48_000, clock: clock)!

        XCTAssertEqual(drift.ppm, 10, accuracy: 0.05)
    }

    func testResidualShowsAnchorJitter() {
        var list = anchors(count: 5, nominal: 48_000, actual: 48_000)
        // средняя точка пришла на 4 мс позже прямой
        list[2].hostTime = HostInstant(ticks: list[2].hostTime.ticks + 4_000, clock: clock)

        let drift = TrackDrift.measure(anchors: list, nominalRate: 48_000, clock: clock)!

        XCTAssertGreaterThan(drift.maxResidualMs, 2)
        XCTAssertLessThan(drift.maxResidualMs, 4.01)
    }

    func testNeedsTwoAnchorsAtLeastTenSecondsApart() {
        XCTAssertNil(TrackDrift.measure(anchors: anchors(count: 1, nominal: 48_000, actual: 48_000),
                                        nominalRate: 48_000, clock: clock))
        let close = [
            TrackAnchor(hostTime: HostInstant(ticks: 0, clock: clock), frame: 0),
            TrackAnchor(hostTime: HostInstant(ticks: 5_000_000, clock: clock), frame: 240_000),
        ]
        XCTAssertNil(TrackDrift.measure(anchors: close, nominalRate: 48_000, clock: clock))
    }

    func testRelativeDriftIsMicMinusSystemOverSessionDuration() {
        let system = TrackDrift.measure(anchors: anchors(count: 3, nominal: 48_000, actual: 48_000),
                                        nominalRate: 48_000, clock: clock)!
        let mic = TrackDrift.measure(anchors: anchors(count: 3, nominal: 48_000, actual: 48_000 * (1 - 4e-6)),
                                     nominalRate: 48_000, clock: clock)!

        let report = DriftReport(system: system, mic: mic, sessionSeconds: 3600)

        XCTAssertEqual(report.relativePpm!, -4, accuracy: 0.05)
        // микрофон даёт меньше кадров: при воспроизведении на номинале он уходит раньше
        XCTAssertEqual(report.driftMsAtEnd!, -14.4, accuracy: 0.2)
        XCTAssertEqual(report.driftMsPer70Min!, -16.8, accuracy: 0.2)
    }

    func testRelativeDriftIsNilWithoutBothTracks() {
        let system = TrackDrift.measure(anchors: anchors(count: 3, nominal: 48_000, actual: 48_000),
                                        nominalRate: 48_000, clock: clock)!

        let report = DriftReport(system: system, mic: nil, sessionSeconds: 90)

        XCTAssertNil(report.relativePpm)
        XCTAssertNil(report.driftMsAtEnd)
    }
}
