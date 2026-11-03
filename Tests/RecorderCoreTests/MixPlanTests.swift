import XCTest
@testable import RecorderCore

final class MixPlanTests: XCTestCase {
    let clock = HostClock(numer: 1000, denom: 1)   // 1 тик = 1 мкс

    func testEarlierTrackStartsAtZeroAndLaterIsDelayedByOffset() {
        // микрофон стартовал на 93 мс раньше системного звука
        let plan = MixPlan(system: .init(firstSampleTicks: 1_000_093_000, sampleRate: 48_000, frames: 480_000),
                           mic: .init(firstSampleTicks: 1_000_000_000, sampleRate: 48_000, frames: 480_000),
                           outputRate: 48_000, clock: clock)

        XCTAssertEqual(plan.originTicks, 1_000_000_000)
        XCTAssertEqual(plan.micLeadFrames, 0)
        XCTAssertEqual(plan.systemLeadFrames, 4_464)       // 93 мс × 48 кГц
        XCTAssertEqual(plan.startOffsetMs!, -93, accuracy: 1e-6)
        XCTAssertEqual(plan.totalFrames, 484_464)
    }

    func testLeadAndLengthAreInOutputRateForResampledMic() {
        // микрофон 24 кГц стартовал на 135 мс позже
        let plan = MixPlan(system: .init(firstSampleTicks: 5_000_000, sampleRate: 48_000, frames: 48_000),
                           mic: .init(firstSampleTicks: 5_135_000, sampleRate: 24_000, frames: 24_000),
                           outputRate: 48_000, clock: clock)

        XCTAssertEqual(plan.systemLeadFrames, 0)
        XCTAssertEqual(plan.micLeadFrames, 6_480)
        XCTAssertEqual(plan.micOutputFrames, 48_000)
        XCTAssertEqual(plan.totalFrames, 54_480)
    }

    func testSingleTrackPlanHasNoOffset() {
        let plan = MixPlan(system: .init(firstSampleTicks: 7, sampleRate: 48_000, frames: 1_000),
                           mic: nil, outputRate: 48_000, clock: clock)

        XCTAssertEqual(plan.systemLeadFrames, 0)
        XCTAssertNil(plan.startOffsetMs)
        XCTAssertEqual(plan.totalFrames, 1_000)
    }
}

final class MixKernelTests: XCTestCase {
    func testStereoSystemKeepsChannelsAndMonoMicGoesToBoth() {
        let out = MixKernel.mix(system: [[0.1, 0.2], [0.3, 0.4]], mic: [[0.5, -0.5]], frames: 2)

        XCTAssertEqual(out.left, [0.6, -0.3], accuracy: 1e-6)
        XCTAssertEqual(out.right, [0.8, -0.1], accuracy: 1e-6)
        XCTAssertEqual(out.clippedSamples, 0)
    }

    func testMonoSystemGoesToBothChannelsAndStereoMicIsAveraged() {
        let out = MixKernel.mix(system: [[0.2]], mic: [[0.4], [0.0]], frames: 1)

        XCTAssertEqual(out.left, [0.4], accuracy: 1e-6)
        XCTAssertEqual(out.right, [0.4], accuracy: 1e-6)
    }

    func testSumAboveFullScaleIsClampedAndCounted() {
        let out = MixKernel.mix(system: [[0.9], [-0.9]], mic: [[0.5]], frames: 1)

        XCTAssertEqual(out.left, [1.0], accuracy: 1e-6)
        XCTAssertEqual(out.right, [-0.4], accuracy: 1e-6)
        XCTAssertEqual(out.clippedSamples, 1)
    }

    func testMissingTrackIsSilence() {
        let out = MixKernel.mix(system: nil, mic: [[0.25, 0.5]], frames: 2)

        XCTAssertEqual(out.left, [0.25, 0.5], accuracy: 1e-6)
        XCTAssertEqual(out.right, [0.25, 0.5], accuracy: 1e-6)
    }
}

private func XCTAssertEqual(_ a: [Float], _ b: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "длины различаются", file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
