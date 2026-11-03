import XCTest
@testable import RecorderCore

final class TrackTimelineTests: XCTestCase {
    // 1 тик = 1 мкс, чтобы считать в уме
    let clock = HostClock(numer: 1000, denom: 1)

    func testFirstBufferSetsFirstSampleHostTimeAndAnchorAtFrameZero() {
        var timeline = TrackTimeline(sampleRate: 48_000, clock: clock)

        let silence = timeline.ingest(hostTime: 5_000_000, frameCount: 480)

        XCTAssertEqual(silence, 0)
        XCTAssertEqual(timeline.firstSampleHostTime, 5_000_000)
        XCTAssertEqual(timeline.framesWritten, 480)
        XCTAssertEqual(timeline.anchors, [TrackAnchor(hostTime: HostInstant(ticks: 5_000_000, clock: clock), frame: 0)])
    }

    func testBufferAfterPauseFillsWholePauseWithoutRecordingAGap() {
        var timeline = TrackTimeline(sampleRate: 48_000, clock: clock)
        _ = timeline.ingest(hostTime: 1_000_000, frameCount: 480)   // ждём следующий на 1,01 с

        // пауза 400 с: больше maxFillSeconds (300 с), но заполняется целиком
        let silence = timeline.ingest(hostTime: 401_010_000, frameCount: 480, afterPause: true)

        XCTAssertEqual(silence, 400 * 48_000)
        XCTAssertEqual(timeline.framesWritten, 480 + 400 * 48_000 + 480)
        XCTAssertTrue(timeline.gaps.isEmpty)
    }

    func testFirstBufferAfterPauseWithoutEarlierDataStartsTrack() {
        var timeline = TrackTimeline(sampleRate: 48_000, clock: clock)

        let silence = timeline.ingest(hostTime: 5_000_000, frameCount: 480, afterPause: true)

        XCTAssertEqual(silence, 0)
        XCTAssertEqual(timeline.firstSampleHostTime, 5_000_000)
    }

    func testContiguousBuffersProduceNoGaps() {
        var timeline = TrackTimeline(sampleRate: 48_000, clock: clock)

        _ = timeline.ingest(hostTime: 1_000_000, frameCount: 480)   // 10 мс
        _ = timeline.ingest(hostTime: 1_010_000, frameCount: 480)
        _ = timeline.ingest(hostTime: 1_020_000, frameCount: 480)

        XCTAssertEqual(timeline.framesWritten, 1440)
        XCTAssertTrue(timeline.gaps.isEmpty)
    }

    func testJitterBelowThresholdIsNotAGap() {
        var timeline = TrackTimeline(sampleRate: 48_000, clock: clock)

        _ = timeline.ingest(hostTime: 1_000_000, frameCount: 480)
        _ = timeline.ingest(hostTime: 1_013_000, frameCount: 480)   // +3 мс

        XCTAssertTrue(timeline.gaps.isEmpty)
    }

    func testMissingDataIsRecordedAsGapAndFilledWithSilence() {
        var timeline = TrackTimeline(sampleRate: 48_000, clock: clock)
        _ = timeline.ingest(hostTime: 1_000_000, frameCount: 480)

        // ожидали 1_010_000, пришло на 250 мс позже
        let silence = timeline.ingest(hostTime: 1_260_000, frameCount: 480)

        XCTAssertEqual(silence, 12_000)
        XCTAssertEqual(timeline.framesWritten, 480 + 12_000 + 480)
        XCTAssertEqual(timeline.gaps.count, 1)
        let gap = timeline.gaps[0]
        XCTAssertEqual(gap.atFrame, 480)
        XCTAssertEqual(gap.hostTime.ticks, 1_260_000)
        XCTAssertEqual(gap.durationMs, 250, accuracy: 1e-6)
        XCTAssertEqual(gap.filledFrames, 12_000)
    }

    func testOverlapIsRecordedAsNegativeGapWithoutFill() {
        var timeline = TrackTimeline(sampleRate: 48_000, clock: clock)
        _ = timeline.ingest(hostTime: 1_000_000, frameCount: 480)

        let silence = timeline.ingest(hostTime: 980_000, frameCount: 480)   // на 30 мс раньше ожидаемого

        XCTAssertEqual(silence, 0)
        XCTAssertEqual(timeline.gaps.count, 1)
        XCTAssertEqual(timeline.gaps[0].durationMs, -30, accuracy: 1e-6)
        XCTAssertEqual(timeline.gaps[0].filledFrames, 0)
        XCTAssertEqual(timeline.framesWritten, 960)
    }

    func testSilenceFillIsCapped() {
        var timeline = TrackTimeline(sampleRate: 1_000, clock: clock, maxFillSeconds: 2)
        _ = timeline.ingest(hostTime: 0, frameCount: 10)

        let silence = timeline.ingest(hostTime: 60_000_000, frameCount: 10)   // через минуту

        XCTAssertEqual(silence, 2_000)
        XCTAssertEqual(timeline.gaps[0].filledFrames, 2_000)
    }

    func testAnchorIsAddedOncePerInterval() {
        var timeline = TrackTimeline(sampleRate: 1_000, clock: clock, anchorIntervalSeconds: 60)

        // 130 буферов по 1 с подряд
        for second in 0..<130 {
            _ = timeline.ingest(hostTime: UInt64(second) * 1_000_000, frameCount: 1_000)
        }

        XCTAssertEqual(timeline.anchors.map(\.frame), [0, 60_000, 120_000])
        XCTAssertEqual(timeline.anchors.map(\.hostTime.ticks), [0, 60_000_000, 120_000_000])
    }

    func testDurationFollowsFramesWritten() {
        var timeline = TrackTimeline(sampleRate: 24_000, clock: clock)
        _ = timeline.ingest(hostTime: 0, frameCount: 36_000)

        XCTAssertEqual(timeline.durationSeconds, 1.5, accuracy: 1e-12)
    }
}
