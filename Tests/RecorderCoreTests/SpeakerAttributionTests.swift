import XCTest
@testable import RecorderCore

final class SpeakerAttributionTests: XCTestCase {
    private func seg(_ id: String, _ track: TranscriptTrack, _ start: Int, _ end: Int,
                     speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, sessionId: "s", track: track,
                          speakerId: speaker ?? (track == .mic ? TranscriptSpeaker.meId : nil),
                          startMs: start, endMs: end, text: id, language: "ru", confidence: 1, modelVersion: "m")
    }

    func testSystemSegmentGetsClusterWithLargestOverlap() {
        let segments = [seg("a", .system, 1000, 5000)]
        let turns = [SpeakerTurn(startMs: 0, endMs: 2000, speaker: 7),
                     SpeakerTurn(startMs: 2000, endMs: 6000, speaker: 3)]
        let result = SpeakerAttribution.apply(segments: segments, sessionId: "s", systemTurns: turns, micTurns: nil)
        XCTAssertEqual(result.segments[0].speakerId, "speaker-1")
        XCTAssertEqual(result.speakers.map(\.label), ["Собеседник 1"])   // реплик mic нет, «Я» не нужен
    }

    func testClustersAreNumberedByFirstReplica() {
        let segments = [seg("a", .system, 0, 1000), seg("b", .system, 2000, 3000), seg("c", .system, 4000, 5000)]
        let turns = [SpeakerTurn(startMs: 0, endMs: 1000, speaker: 9),
                     SpeakerTurn(startMs: 2000, endMs: 3000, speaker: 2),
                     SpeakerTurn(startMs: 4000, endMs: 5000, speaker: 9)]
        let result = SpeakerAttribution.apply(segments: segments, sessionId: "s", systemTurns: turns, micTurns: nil)
        XCTAssertEqual(result.segments.map(\.speakerId), ["speaker-1", "speaker-2", "speaker-1"])
        XCTAssertEqual(result.speakers.last, TranscriptSpeaker(id: "speaker-2", sessionId: "s",
                                                               label: "Собеседник 2", displayName: nil))
    }

    func testSegmentBetweenTurnsTakesNearestTurnWithinTwoSeconds() {
        let segments = [seg("a", .system, 3000, 3500), seg("b", .system, 20_000, 21_000)]
        let turns = [SpeakerTurn(startMs: 0, endMs: 2000, speaker: 1),
                     SpeakerTurn(startMs: 4000, endMs: 6000, speaker: 5)]
        let result = SpeakerAttribution.apply(segments: segments, sessionId: "s", systemTurns: turns, micTurns: nil)
        XCTAssertEqual(result.segments[0].speakerId, "speaker-1")   // до второго хода 500 мс
        XCTAssertNil(result.segments[1].speakerId)                    // дальше 2 с от любого хода
    }

    func testMicStaysMeWithoutMultipleVoices() {
        let segments = [seg("m", .mic, 0, 1000)]
        let result = SpeakerAttribution.apply(segments: segments, sessionId: "s", systemTurns: [], micTurns: nil)
        XCTAssertEqual(result.segments[0].speakerId, "me")
        XCTAssertEqual(result.speakers.map(\.id), ["me"])
    }

    func testMicWithMultipleVoicesKeepsDominantClusterAsMe() {
        let segments = [seg("s", .system, 0, 1000),
                        seg("m1", .mic, 2000, 8000), seg("m2", .mic, 9000, 10_000), seg("m3", .mic, 11_000, 15_000)]
        let system = [SpeakerTurn(startMs: 0, endMs: 1000, speaker: 0)]
        let mic = [SpeakerTurn(startMs: 2000, endMs: 8000, speaker: 0),
                   SpeakerTurn(startMs: 9000, endMs: 10_000, speaker: 1),
                   SpeakerTurn(startMs: 11_000, endMs: 15_000, speaker: 0)]
        let result = SpeakerAttribution.apply(segments: segments, sessionId: "s", systemTurns: system, micTurns: mic)
        XCTAssertEqual(result.segments.map(\.speakerId), ["speaker-1", "me", "speaker-2", "me"])
        XCTAssertEqual(result.speakers.map(\.label), ["Я", "Собеседник 1", "Собеседник 2"])
    }

    func testOverlapsLinkDifferentSpeakersOnly() {
        let segments = [seg("s1", .system, 0, 3000, speaker: "speaker-1"),
                        seg("m1", .mic, 2500, 4000),                       // перебивание 500 мс
                        seg("s2", .system, 2900, 5000, speaker: "speaker-1"),  // тот же говорящий
                        seg("s3", .system, 3900, 6000, speaker: "speaker-2")]  // с m1 100 мс: мало
        let overlaps = SpeakerAttribution.overlaps(segments)
        XCTAssertEqual(overlaps["s1"], ["m1"])
        XCTAssertEqual(overlaps["m1"], ["s1", "s2"])
        XCTAssertEqual(overlaps["s2"], ["m1", "s3"])
        XCTAssertEqual(overlaps["s3"], ["s2"])
    }

    func testApplyFillsOverlapWith() {
        let segments = [seg("s", .system, 0, 3000), seg("m", .mic, 2000, 4000)]
        let turns = [SpeakerTurn(startMs: 0, endMs: 3000, speaker: 0)]
        let result = SpeakerAttribution.apply(segments: segments, sessionId: "s", systemTurns: turns, micTurns: nil)
        XCTAssertEqual(result.segments.map(\.overlapWith), [["m"], ["s"]])
    }

    func testApplyReplacesPreviousAttribution() {
        let segments = [seg("s", .system, 0, 1000, speaker: "speaker-4")]
        var old = segments
        old[0].overlapWith = ["x"]
        let result = SpeakerAttribution.apply(segments: old, sessionId: "s", systemTurns: [], micTurns: nil)
        XCTAssertNil(result.segments[0].speakerId)
        XCTAssertEqual(result.segments[0].overlapWith, [])
    }
}

final class DiarizationEvaluationTests: XCTestCase {
    private func seg(_ id: String, _ track: TranscriptTrack, _ start: Int, _ speaker: String?) -> TranscriptSegment {
        TranscriptSegment(id: id, sessionId: "s", track: track, speakerId: speaker, startMs: start, endMs: start + 2000,
                          text: id, language: "ru", confidence: 1, modelVersion: "m")
    }

    func testParsesAudacityLabels() {
        let text = "1.5\t1.5\tОльга\n2.25\t2.25\tя\n\n3\t3.5\t Вова \n"
        XCTAssertEqual(ReferenceLabel.parseAudacity(text),
                       [ReferenceLabel(ms: 1500, name: "Ольга"), ReferenceLabel(ms: 2250, name: "я"),
                        ReferenceLabel(ms: 3000, name: "Вова")])
    }

    func testCountsMeLabelsByMicAndMapsClustersOneToOne() {
        let segments = [seg("a", .system, 1000, "speaker-1"), seg("b", .system, 5000, "speaker-2"),
                        seg("c", .system, 9000, "speaker-1"), seg("d", .mic, 13_000, "me"),
                        seg("e", .system, 17_000, "speaker-3")]
        let labels = [ReferenceLabel(ms: 1200, name: "Ольга"), ReferenceLabel(ms: 5100, name: "Вова"),
                      ReferenceLabel(ms: 8800, name: "Ольга"), ReferenceLabel(ms: 13_100, name: "Я"),
                      ReferenceLabel(ms: 17_300, name: "Ольга")]
        let report = DiarizationEvaluation.evaluate(labels: labels, segments: segments)
        XCTAssertEqual(report.total, 5)
        // speaker-1 = Ольга, speaker-2 = Вова; speaker-3 не может стать второй Ольгой
        XCTAssertEqual(report.correct, 4)
        XCTAssertEqual(report.meTotal, 1)
        XCTAssertEqual(report.meCorrect, 1)
        XCTAssertEqual(report.mapping["speaker-1"], "Ольга")
        XCTAssertEqual(report.mapping["speaker-2"], "Вова")
        XCTAssertNil(report.mapping["speaker-3"])
        XCTAssertEqual(report.correctManyToOne, 5)
    }

    func testPurityCountsMeLabelsAndDominantNamePerCluster() {
        // speaker-1: Ольга, Ольга, Вова (смешение); speaker-2 и speaker-3: дробление Вовы
        let segments = [seg("a", .system, 1000, "speaker-1"), seg("b", .system, 5000, "speaker-1"),
                        seg("c", .system, 9000, "speaker-1"), seg("d", .system, 13_000, "speaker-2"),
                        seg("e", .system, 17_000, "speaker-3"), seg("m", .mic, 21_000, "me"),
                        seg("n", .mic, 25_000, "speaker-2")]
        let labels = [ReferenceLabel(ms: 1000, name: "Ольга"), ReferenceLabel(ms: 5000, name: "Ольга"),
                      ReferenceLabel(ms: 9000, name: "Вова"), ReferenceLabel(ms: 13_000, name: "Вова"),
                      ReferenceLabel(ms: 17_000, name: "Вова"), ReferenceLabel(ms: 21_000, name: "я"),
                      ReferenceLabel(ms: 25_000, name: "я")]
        let report = DiarizationEvaluation.evaluate(labels: labels, segments: segments)
        // Чистота с «я» (решение пользователя 02.11.2026): 4 собеседника + 1 «я» из 7 меток
        XCTAssertEqual(report.othersTotal, 5)
        XCTAssertEqual(report.othersCorrectManyToOne, 4)
        XCTAssertEqual(report.meCorrect, 1)
        XCTAssertEqual(report.purity, 5.0 / 7.0, accuracy: 1e-9)
        XCTAssertEqual(report.clusters, 3)
        XCTAssertEqual(report.names, 2)
        XCTAssertEqual(report.clustersPerSpeaker, 1.5, accuracy: 1e-9)
        XCTAssertEqual(report.maxClustersOfOneSpeaker, 2)   // Вова в speaker-2 и speaker-3
        XCTAssertFalse(report.meetsCriterion)                // 71% < 85%
    }

    func testCriterionNeedsPurityAndClusterLimit() {
        // Один человек раздроблен на 6 кластеров без смешения: чистота 100%
        let segments = (0..<6).map { seg("s\($0)", .system, $0 * 4000, "speaker-\($0 + 1)") }
        let labels = (0..<6).map { ReferenceLabel(ms: $0 * 4000, name: "Ольга") }
        let split = DiarizationEvaluation.evaluate(labels: labels, segments: segments)
        XCTAssertEqual(split.purity, 1, accuracy: 1e-9)
        XCTAssertEqual(split.clusters, 6)
        XCTAssertFalse(split.meetsCriterion)   // 6 кластеров на 1 собеседника > 5

        let fine = DiarizationEvaluation.evaluate(labels: Array(labels.prefix(5)), segments: segments)
        XCTAssertTrue(fine.meetsCriterion)
    }

    func testLabelWithoutNearbyReplicaIsWrong() {
        let segments = [seg("a", .system, 1000, "speaker-1")]
        let labels = [ReferenceLabel(ms: 1000, name: "Ольга"), ReferenceLabel(ms: 30_000, name: "Ольга"),
                      ReferenceLabel(ms: 1100, name: "я")]
        let report = DiarizationEvaluation.evaluate(labels: labels, segments: segments)
        XCTAssertEqual(report.total, 3)
        XCTAssertEqual(report.correct, 1)
        XCTAssertEqual(report.unmatched, 1)   // для второй «Ольги» рядом нет реплик
        XCTAssertEqual(report.meCorrect, 0)   // «я» попала на реплику system
    }

    func testPrefersReplicaOfExpectedTrackNearLabel() {
        // Перебивание: реплика mic начинается ближе к метке собеседника, чем его реплика system
        let segments = [seg("m", .mic, 1100, "me"), seg("s", .system, 1600, "speaker-1")]
        let labels = [ReferenceLabel(ms: 1000, name: "Ольга"), ReferenceLabel(ms: 1050, name: "я")]
        let report = DiarizationEvaluation.evaluate(labels: labels, segments: segments)
        XCTAssertEqual(report.correct, 2)
    }
}
