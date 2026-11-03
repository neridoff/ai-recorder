import XCTest
@testable import RecorderCore

final class TranscriptMarkdownTests: XCTestCase {
    private func seg(_ id: String, _ speaker: String?, _ start: Int, _ end: Int, _ text: String,
                     confidence: Double = 0.9, overlap: [String] = []) -> TranscriptSegment {
        TranscriptSegment(id: id, sessionId: "s", track: speaker == "me" ? .mic : .system, speakerId: speaker,
                          startMs: start, endMs: end, text: text, language: "ru", confidence: confidence,
                          overlapWith: overlap, modelVersion: "m")
    }

    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        let speakers = [TranscriptSpeaker(id: "me", sessionId: "s", label: "Я"),
                        TranscriptSpeaker(id: "speaker-1", sessionId: "s", label: "Собеседник 1"),
                        TranscriptSpeaker(id: "speaker-2", sessionId: "s", label: "Собеседник 2")]
        return Transcript(schemaVersion: 1, sessionId: "s", modelVersion: "m", language: "ru", systemVAD: true,
                          createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                          chunks: [], segments: segments, speakers: speakers)
    }

    private func body(_ markdown: String) -> String {
        String(markdown[markdown.range(of: "## Текст\n\n")!.upperBound...])
    }

    func testMergesSameSpeakerWithinThreeSecondsAndFormatsMinutes() {
        let md = TranscriptMarkdown.render(transcript(
            [seg("a", "speaker-1", 1000, 4000, "Привет."),
             seg("b", "speaker-1", 7000, 9000, "Как дела?"),           // пауза 3 с: склеивается
             seg("c", "speaker-1", 12_001, 13_000, "Начнём."),         // пауза 3,001 с: новый блок
             seg("d", "me", 65_000, 70_000, "Хорошо"),
             seg("e", nil, 3_725_000, 3_726_000, "шум")]), title: "Встреча s")
        XCTAssertEqual(body(md), """
            **[00:01] Собеседник 1:** Привет. Как дела?

            **[00:12] Собеседник 1:** Начнём.

            **[01:05] Я:** Хорошо

            **[62:05] Не определён:** шум

            """)
    }

    func testMarksInterruptionsWithOtherSpeakers() {
        let md = TranscriptMarkdown.render(transcript(
            [seg("a", "speaker-1", 0, 5000, "Я думаю, что", overlap: ["b"]),
             seg("b", "me", 4000, 6000, "Да", overlap: ["a"]),
             seg("c", "speaker-1", 6500, 8000, "надо начать.")]), title: "Встреча s")
        XCTAssertEqual(body(md), """
            **[00:00] Собеседник 1:** _(перебивание: Я)_ Я думаю, что

            **[00:04] Я:** _(перебивание: Собеседник 1)_ Да

            **[00:06] Собеседник 1:** надо начать.

            """)
    }

    func testAssessmentBlockComesFirstWithCountsAndPlaceholders() {
        let md = TranscriptMarkdown.render(transcript(
            [seg("a", "speaker-1", 0, 2000, "Спасибо.", confidence: 0.3, overlap: ["b"]),
             seg("b", "me", 1000, 3000, "Ага", overlap: ["a"]),
             seg("c", "speaker-2", 60_000, 61_000, "Да"),
             seg("d", nil, 120_000, 121_000, "…")]), title: "Встреча s", durationSeconds: 125, multipleVoices: true)
        let assessment = String(md[md.range(of: "## Оценка")!.lowerBound..<md.range(of: "## Текст")!.lowerBound])
        XCTAssertTrue(md.hasPrefix("# Встреча s\n"))
        XCTAssertTrue(assessment.contains("Собеседников по разметке: 2"), assessment)
        XCTAssertTrue(assessment.contains("Я 1, Собеседник 1 1, Собеседник 2 1, без говорящего 1"), assessment)
        XCTAssertTrue(assessment.contains("ниже 50%: 1"), assessment)
        XCTAssertTrue(assessment.contains("перебиваний 2"), assessment)
        XCTAssertTrue(assessment.contains("несколько голосов в комнате"), assessment)
        XCTAssertTrue(assessment.contains("Пригодность текста"), assessment)
        XCTAssertTrue(md.contains("Длительность 2 мин, реплик 4"), md)
    }

    func testWritesFileNextToTranscript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TranscriptMarkdown.write(transcript([seg("a", "me", 0, 1000, "Тест")]), meta: nil, to: dir)
        XCTAssertEqual(url.lastPathComponent, "transcript.md")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("**[00:00] Я:** Тест"))
    }
}
