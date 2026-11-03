import XCTest
@testable import RecorderCore

/// Разметка-заглушка: возвращает заданные ходы (мс от начала дорожки) по имени файла дорожки.
final class FakeDiarizer: SpeakerDiarizer {
    let modelVersion = "fake-diar-1"
    var turns: [Int: [SpeakerTurn]] = [:]   // длина звука → ходы, чтобы различать дорожки
    var calls: [Int] = []

    func diarize(_ samples: [Float], progress: @escaping (Double) -> Void) throws -> [SpeakerTurn] {
        calls.append(samples.count)
        progress(1)
        return turns[samples.count] ?? []
    }
}

final class DiarizationJobTests: XCTestCase {
    var root: URL!
    var dir: URL!
    let clock = HostClock(numer: 1000, denom: 1)
    let systemSamples = 60 * 16_000
    let micSamples = 60 * 16_000 + 1   // другая длина, чтобы заглушка различала дорожки

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dir = root.appendingPathComponent("2026-10-29_12-02-22")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSession(multipleVoices: Bool? = nil) throws {
        var meta = SessionMetadata.new(startedAt: Date(timeIntervalSince1970: 1_800_000_000), clock: clock)
        meta.status = .completed
        meta.system = TrackMetadata(file: "system.caf", sampleRate: 48_000, channels: 2, deviceName: "T")
        meta.system?.durationSeconds = 60
        meta.mic = TrackMetadata(file: "mic.caf", sampleRate: 24_000, channels: 1, deviceName: "T")
        meta.mic?.durationSeconds = 60
        meta.multipleVoices = multipleVoices
        meta.alignment = AlignmentRecord(
            analyzedAt: Date(timeIntervalSince1970: 1_800_000_000), mixFile: "mixed.m4a",
            outputSampleRate: 48_000, originHostTime: HostInstant(ticks: 0, clock: clock),
            startOffsetMs: -100, systemLeadMs: 100, micLeadMs: 0, mixDurationSeconds: 0,
            clippedSamples: 0, drift: DriftReport(system: nil, mic: nil, sessionSeconds: 0))
        try SessionStore(root: root).write(meta, to: dir)
    }

    private func seg(_ id: String, _ track: TranscriptTrack, _ start: Int, _ end: Int) -> TranscriptSegment {
        TranscriptSegment(id: id, sessionId: dir.lastPathComponent, track: track,
                          speakerId: track == .mic ? TranscriptSpeaker.meId : nil,
                          startMs: start, endMs: end, text: id, language: "ru", confidence: 1, modelVersion: "w")
    }

    private func writeTranscript(complete: Bool = true, segments: [TranscriptSegment]) throws {
        let t = Transcript(schemaVersion: 1, sessionId: dir.lastPathComponent, modelVersion: "w", language: "ru",
                           systemVAD: true, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                           updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                           chunks: [TranscriptChunk(track: .system, index: 0, startSample: 0, endSample: systemSamples,
                                                    done: complete)],
                           segments: segments, speakers: [])
        try SessionMetadata.encoder.encode(t).write(to: dir.appendingPathComponent(Transcript.fileName))
    }

    private func job(_ diarizer: FakeDiarizer, multipleVoices: Bool? = nil) -> DiarizationJob {
        DiarizationJob(directory: dir, diarizer: diarizer, multipleVoices: multipleVoices,
                       loadAudio: { [unowned self] url in
                           [Float](repeating: 0.1, count: url.lastPathComponent == "system.caf"
                                   ? self.systemSamples : self.micSamples)
                       })
    }

    private func readMeta() throws -> SessionMetadata { try SessionStore(root: root).read(from: dir) }

    func testLabelsSystemByClustersShiftedBySystemLead() throws {
        try writeSession()
        try writeTranscript(segments: [seg("s0", .system, 1100, 3100), seg("m0", .mic, 2500, 4000),
                                       seg("s1", .system, 5100, 7100)])
        let diarizer = FakeDiarizer()
        // время дорожки: +100 мс до таймлайна
        diarizer.turns[systemSamples] = [SpeakerTurn(startMs: 1000, endMs: 3000, speaker: 4),
                                         SpeakerTurn(startMs: 5000, endMs: 7000, speaker: 2)]

        let t = try job(diarizer).run()

        XCTAssertEqual(diarizer.calls, [systemSamples])   // mic без флага не размечается
        XCTAssertEqual(t.segments.map(\.speakerId), ["speaker-1", "me", "speaker-2"])
        XCTAssertEqual(t.segments.map(\.overlapWith), [["m0"], ["s0"], []])
        XCTAssertEqual(t.speakers.map(\.label), ["Я", "Собеседник 1", "Собеседник 2"])
        XCTAssertEqual(t.speakers.map(\.displayName), [nil, nil, nil])
        XCTAssertEqual(t.diarization?.modelVersion, "fake-diar-1")
        XCTAssertEqual(t.diarization?.micDiarized, false)
        let saved = try SessionMetadata.decoder.decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent(Transcript.fileName)))
        XCTAssertEqual(saved, t)
    }

    func testRecordsDiarizationStatus() throws {
        try writeSession()
        try writeTranscript(segments: [seg("s0", .system, 0, 1000)])
        let diarizer = FakeDiarizer()
        diarizer.turns[systemSamples] = [SpeakerTurn(startMs: 0, endMs: 1000, speaker: 0)]

        _ = try job(diarizer).run()

        let record = try XCTUnwrap(try readMeta().diarization)
        XCTAssertEqual(record.status, .done)
        XCTAssertEqual(record.progress, 1)
        XCTAssertEqual(record.speakers, 1)
        XCTAssertEqual(record.audioSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(record.micDiarized, false)
        XCTAssertEqual(record.modelVersion, "fake-diar-1")
        XCTAssertNotNil(record.finishedAt)
        XCTAssertEqual(try readMeta().schemaVersion, 6)
    }

    func testMultipleVoicesFlagInSessionDiarizesMic() throws {
        try writeSession(multipleVoices: true)
        try writeTranscript(segments: [seg("m0", .mic, 0, 5000), seg("m1", .mic, 6000, 7000)])
        let diarizer = FakeDiarizer()
        diarizer.turns[micSamples] = [SpeakerTurn(startMs: 0, endMs: 5000, speaker: 0),
                                      SpeakerTurn(startMs: 6000, endMs: 7000, speaker: 1)]

        let t = try job(diarizer).run()

        XCTAssertEqual(diarizer.calls, [systemSamples, micSamples])
        XCTAssertEqual(t.segments.map(\.speakerId), ["me", "speaker-1"])
        XCTAssertEqual(t.diarization?.micDiarized, true)
        XCTAssertEqual(try readMeta().diarization?.micDiarized, true)
    }

    func testExplicitFlagOverridesSession() throws {
        try writeSession(multipleVoices: true)
        try writeTranscript(segments: [seg("m0", .mic, 0, 5000)])
        let diarizer = FakeDiarizer()

        _ = try job(diarizer, multipleVoices: false).run()

        XCTAssertEqual(diarizer.calls, [systemSamples])
    }

    func testRequiresCompleteTranscript() throws {
        try writeSession()
        try writeTranscript(complete: false, segments: [])
        XCTAssertThrowsError(try job(FakeDiarizer()).run()) { error in
            XCTAssertEqual(error as? DiarizationError, .noTranscript)
        }
        XCTAssertEqual(try readMeta().diarization?.status, .failed)
    }

    func testNewTranscriptionClearsDiarization() throws {
        try writeSession()
        try writeTranscript(segments: [seg("s0", .system, 0, 1000)])
        _ = try job(FakeDiarizer()).run()
        XCTAssertNotNil(try readMeta().diarization)

        let engine = FakeEngine()
        engine.speech = [(0, 1000)]
        _ = try TranscriptionJob(directory: dir, engine: engine, clock: clock,
                                 loadAudio: { _ in [Float](repeating: 0.5, count: 16_000) }, align: { _ in })
            .run(restart: true)

        XCTAssertNil(try readMeta().diarization)
    }
}
