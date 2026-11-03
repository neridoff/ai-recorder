import XCTest
@testable import RecorderCore

final class SpeechGateTests: XCTestCase {
    func testDropsSpansFarBelowLoudSpeech() {
        let spans = [
            SpeechSpan(startMs: 0, endMs: 5_000, rmsDb: -41),        // шум, принятый VAD за речь
            SpeechSpan(startMs: 10_000, endMs: 20_000, rmsDb: -15),  // речь пользователя
            SpeechSpan(startMs: 21_000, endMs: 30_000, rmsDb: -17),
            SpeechSpan(startMs: 31_000, endMs: 32_000, rmsDb: -27),  // тихая, но в пределах 18 дБ
        ]

        let kept = SpeechGate.filter(spans)

        XCTAssertEqual(kept.map(\.startMs), [10_000, 21_000, 31_000])
    }

    func testReferenceIsWeightedByDuration() {
        // одна короткая громкая вспышка не должна задирать порог для длинной речи
        let spans = [
            SpeechSpan(startMs: 0, endMs: 200, rmsDb: -3),
            SpeechSpan(startMs: 1_000, endMs: 60_000, rmsDb: -25),
        ]

        XCTAssertEqual(SpeechGate.filter(spans).count, 2)
    }

    func testDropsSpansBelowAbsoluteFloor() {
        let spans = [SpeechSpan(startMs: 0, endMs: 10_000, rmsDb: -60)]

        XCTAssertTrue(SpeechGate.filter(spans).isEmpty)
    }

    func testEmptyInput() {
        XCTAssertTrue(SpeechGate.filter([]).isEmpty)
    }
}

final class ChunkPlannerTests: XCTestCase {
    let rate = 16_000

    /// Энергия по окнам 100 мс: везде громко, кроме тихих окон в указанных секундах.
    private func energy(seconds: Int, quietAt: [Double]) -> [Float] {
        var e = [Float](repeating: 1, count: seconds * 10)
        for s in quietAt { e[Int(s * 10)] = 0 }
        return e
    }

    func testShortTrackIsOneChunk() {
        let chunks = ChunkPlanner.plan(track: .system, totalSamples: 120 * rate, excluded: [],
                                       windowEnergy: energy(seconds: 120, quietAt: []))

        XCTAssertEqual(chunks, [TranscriptChunk(track: .system, index: 0, startSample: 0, endSample: 120 * rate)])
    }

    func testBoundaryMovesToQuietestWindowNearFiveMinutes() {
        let chunks = ChunkPlanner.plan(track: .system, totalSamples: 600 * rate, excluded: [],
                                       windowEnergy: energy(seconds: 600, quietAt: [297.3]))

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startSample, 0)
        // середина тихого окна 297.3–297.4 с
        XCTAssertEqual(chunks[0].endSample, Int(297.35 * Double(rate)))
        XCTAssertEqual(chunks[1].startSample, chunks[0].endSample)
        XCTAssertEqual(chunks[1].endSample, 600 * rate)
    }

    func testQuietWindowOutsideSearchRangeIsIgnored() {
        let chunks = ChunkPlanner.plan(track: .system, totalSamples: 600 * rate, excluded: [],
                                       windowEnergy: energy(seconds: 600, quietAt: [280]))

        // тишины в ±5 с нет: граница ровно на 5 минутах (первое окно с минимальной энергией)
        XCTAssertEqual(chunks[0].endSample, Int(295.05 * Double(rate)))
    }

    func testShortTailIsMergedIntoPreviousChunk() {
        let chunks = ChunkPlanner.plan(track: .mic, totalSamples: 320 * rate, excluded: [],
                                       windowEnergy: energy(seconds: 320, quietAt: []))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].endSample, 320 * rate)
    }

    func testExcludedRangesSplitTrackAndAreSkipped() {
        // пауза записи с 100 по 200 с
        let chunks = ChunkPlanner.plan(track: .system, totalSamples: 400 * rate,
                                       excluded: [100 * rate ..< 200 * rate],
                                       windowEnergy: energy(seconds: 400, quietAt: []))

        XCTAssertEqual(chunks.map(\.startSample), [0, 200 * rate])
        XCTAssertEqual(chunks.map(\.endSample), [100 * rate, 400 * rate])
        XCTAssertEqual(chunks.map(\.index), [0, 1])
    }
}

final class SegmentMappingTests: XCTestCase {
    func testAddsChunkOffsetAndTrackLead() {
        let chunk = TranscriptChunk(track: .mic, index: 2, startSample: 16_000 * 300, endSample: 16_000 * 600)
        let engine = [EngineSegment(startMs: 1_000, endMs: 2_500, text: "Привет", confidence: 0.9)]

        let segments = SegmentMapping.map(engine, chunk: chunk, leadMs: 115.4, sessionId: "s", modelVersion: "m", language: "ru")

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].id, "mic-2-0")
        XCTAssertEqual(segments[0].startMs, 301_115)
        XCTAssertEqual(segments[0].endMs, 302_615)
        XCTAssertEqual(segments[0].speakerId, "me")
        XCTAssertEqual(segments[0].track, .mic)
        XCTAssertEqual(segments[0].language, "ru")
    }

    func testSystemSegmentsHaveNoSpeakerUntilDiarization() {
        let chunk = TranscriptChunk(track: .system, index: 0, startSample: 0, endSample: 16_000 * 10)
        let engine = [EngineSegment(startMs: 0, endMs: 1_000, text: "Да", confidence: 1)]

        let segments = SegmentMapping.map(engine, chunk: chunk, leadMs: 0, sessionId: "s", modelVersion: "m", language: "ru")

        XCTAssertNil(segments[0].speakerId)
    }

    func testSegmentsBeyondChunkEndAreDroppedOrClamped() {
        // whisper иногда выдаёт «Продолжение следует...» за концом звука
        let chunk = TranscriptChunk(track: .system, index: 0, startSample: 0, endSample: 16_000 * 120)
        let engine = [
            EngineSegment(startMs: 113_000, endMs: 121_000, text: "Кто?", confidence: 0.8),
            EngineSegment(startMs: 120_000, endMs: 149_000, text: "Продолжение следует...", confidence: 0.9),
        ]

        let segments = SegmentMapping.map(engine, chunk: chunk, leadMs: 0, sessionId: "s", modelVersion: "m", language: "ru")

        XCTAssertEqual(segments.map(\.text), ["Кто?"])
        XCTAssertEqual(segments[0].endMs, 120_000)
    }
}

final class SpeechWindowsTests: XCTestCase {
    private func span(_ a: Double, _ b: Double) -> SpeechSpan {
        SpeechSpan(startMs: Int(a * 1000), endMs: Int(b * 1000), rmsDb: -15)
    }

    func testCloseSpansShareOneWindowWithPadding() {
        let windows = SpeechWindows.plan([span(10, 12), span(13, 15), span(18, 20)], within: 0 ..< 600_000)

        XCTAssertEqual(windows, [9_800 ..< 20_200])
    }

    func testWindowIsClosedBeforeExceedingMaxLength() {
        let windows = SpeechWindows.plan([span(0, 10), span(12, 20), span(22, 29), span(31, 40)], within: 0 ..< 600_000)

        XCTAssertEqual(windows, [0 ..< 29_200, 30_800 ..< 40_200])
    }

    func testLongSilenceStartsNewWindow() {
        let windows = SpeechWindows.plan([span(10, 12), span(20, 22)], within: 0 ..< 600_000)

        XCTAssertEqual(windows.count, 2)
    }

    func testSpanLongerThanMaxIsOneWindow() {
        let windows = SpeechWindows.plan([span(5, 70)], within: 0 ..< 600_000)

        XCTAssertEqual(windows, [4_800 ..< 70_200])
    }

    func testWindowsAreClippedToChunkAndSpansOutsideAreIgnored() {
        let windows = SpeechWindows.plan([span(1, 3), span(299, 302), span(400, 401)], within: 0 ..< 300_000)

        XCTAssertEqual(windows, [800 ..< 3_200, 298_800 ..< 300_000])
    }
}
