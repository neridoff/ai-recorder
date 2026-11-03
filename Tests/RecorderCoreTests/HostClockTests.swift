import XCTest
@testable import RecorderCore

final class HostClockTests: XCTestCase {
    // Apple Silicon: 125/3 нс на тик (24 МГц)
    let clock = HostClock(numer: 125, denom: 3)

    func testConvertsTicksToSeconds() {
        XCTAssertEqual(clock.seconds(24_000_000), 1.0, accuracy: 1e-12)
    }

    func testConvertsSecondsToTicks() {
        XCTAssertEqual(clock.ticks(seconds: 2.5), 60_000_000)
    }

    func testSignedMillisecondsBetweenInstants() {
        XCTAssertEqual(clock.milliseconds(from: 24_000_000, to: 27_240_000), 135, accuracy: 1e-9)
        XCTAssertEqual(clock.milliseconds(from: 27_240_000, to: 24_000_000), -135, accuracy: 1e-9)
    }

    func testSystemClockMatchesMachTimebase() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        XCTAssertEqual(HostClock.system.numer, info.numer)
        XCTAssertEqual(HostClock.system.denom, info.denom)
    }
}
