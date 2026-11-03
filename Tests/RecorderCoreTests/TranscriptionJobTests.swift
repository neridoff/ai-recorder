import XCTest
@testable import RecorderCore

/// Движок-заглушка: на каждый запрос одна реплика с номером вызова, VAD = заданные отрезки.
final class FakeEngine: TranscriptionEngine {
    let modelVersion: String
    var requests: [EngineRequest] = []
    var speech: [(startMs: Int, endMs: Int)] = []
    /// Бросить отмену на вызове с этим номером (с нуля).
    var cancelOnCall: Int?

    init(modelVersion: String = "fake-1") {
        self.modelVersion = modelVersion
    }

    func transcribe(_ request: EngineRequest, progress: @escaping (Double) -> Void,
                    isCancelled: @escaping () -> Bool) throws -> [EngineSegment] {
        if requests.count == cancelOnCall { throw TranscriptionError.cancelled }
        requests.append(request)
        progress(1)
        return [EngineSegment(startMs: 1_000, endMs: 2_000, text: "реплика \(requests.count)", confidence: 0.9)]
    }

    func detectSpeech(_ samples: [Float]) throws -> [(startMs: Int, endMs: Int)] { speech }
}

final class TranscriptionJobTests: XCTestCase {
    var root: URL!
    var dir: URL!
    let clock = HostClock(numer: 1000, denom: 1)
    let rate = 16_000
    /// Звук дорожек для загрузчика: по умолчанию 0.5 по всей длине.
    var audio: [String: [Float]] = [:]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dir = root.appendingPathComponent("2026-10-29_12-02-22")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSession(seconds: Int, status: SessionStatus = .completed, aligned: Bool = true,
                              segments: [RecordingSegment]? = nil) throws {
        var meta = SessionMetadata.new(startedAt: Date(timeIntervalSince1970: 1_800_000_000), clock: clock)
        meta.status = status
        meta.system = TrackMetadata(file: "system.caf", sampleRate: 48_000, channels: 2, deviceName: "T")
        meta.system?.durationSeconds = Double(seconds)
        meta.system?.framesWritten = Int64(seconds * 48_000)
        meta.mic = TrackMetadata(file: "mic.caf", sampleRate: 24_000, channels: 1, deviceName: "T")
        meta.mic?.durationSeconds = Double(seconds)
        meta.mic?.framesWritten = Int64(seconds * 24_000)
        meta.segments = segments
        if aligned { meta.alignment = alignment() }
        try SessionStore(root: root).write(meta, to: dir)
        audio["system.caf"] = [Float](repeating: 0.5, count: seconds * rate)
        audio["mic.caf"] = [Float](repeating: 0.5, count: seconds * rate)
    }

    private func alignment() -> AlignmentRecord {
        AlignmentRecord(analyzedAt: Date(timeIntervalSince1970: 1_800_000_000), mixFile: "mixed.m4a",
                        outputSampleRate: 48_000, originHostTime: HostInstant(ticks: 0, clock: clock),
                        startOffsetMs: -115, systemLeadMs: 115, micLeadMs: 0, mixDurationSeconds: 0,
                        clippedSamples: 0, drift: DriftReport(system: nil, mic: nil, sessionSeconds: 0))
    }

    /// По умолчанию system целиком: так тесты проверяют чанки без окон VAD.
    private func job(_ engine: FakeEngine, align: @escaping (URL) throws -> Void = { _ in }) -> TranscriptionJob {
        TranscriptionJob(directory: dir, engine: engine, systemVAD: false, clock: clock,
                         loadAudio: { [unowned self] url in self.audio[url.lastPathComponent]! },
                         align: align)
    }

    private func readMeta() throws -> SessionMetadata { try SessionStore(root: root).read(from: dir) }

    private func readTranscript() throws -> Transcript {
        let data = try Data(contentsOf: dir.appendingPathComponent(Transcript.fileName))
        return try SessionMetadata.decoder.decode(Transcript.self, from: data)
    }

    func testWritesTranscriptWithBothTracksAndAlignedTimecodes() throws {
        try writeSession(seconds: 60)
        let engine = FakeEngine()
        engine.speech = [(0, 60_000)]

        let transcript = try job(engine).run()

        XCTAssertTrue(transcript.isComplete)
        XCTAssertEqual(transcript.sessionId, "2026-10-29_12-02-22")
        XCTAssertEqual(transcript.segments.map(\.track), [.mic, .system])   // по времени начала
        XCTAssertEqual(transcript.segments.map(\.startMs), [1_000, 1_115])
        XCTAssertEqual(transcript.speakers.map(\.label), ["Я"])
        XCTAssertEqual(try readTranscript(), transcript)
        XCTAssertEqual(engine.requests.map(\.language), ["ru", "ru"])
    }

    func testRecordsDoneStatusInSessionJSON() throws {
        try writeSession(seconds: 60)
        let engine = FakeEngine()
        engine.speech = [(0, 30_000)]

        _ = try job(engine).run()

        let record = try XCTUnwrap(try readMeta().transcription)
        XCTAssertEqual(record.status, .done)
        XCTAssertEqual(record.progress, 1)
        XCTAssertEqual(record.chunksDone, 2)
        XCTAssertEqual(record.chunksTotal, 2)
        XCTAssertEqual(record.audioSeconds, 120, accuracy: 0.01)
        XCTAssertEqual(record.micSpeechSeconds ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(record.modelVersion, "fake-1")
        XCTAssertNotNil(record.finishedAt)
        XCTAssertEqual(try readMeta().schemaVersion, 6)
    }

    func testResumesFromLastFinishedChunkAfterFailure() throws {
        try writeSession(seconds: 600)   // system: 2 чанка, mic: 2 чанка
        let first = FakeEngine()
        first.speech = [(0, 600_000)]
        first.cancelOnCall = 2

        XCTAssertThrowsError(try job(first).run()) { XCTAssertEqual($0 as? TranscriptionError, .cancelled) }
        XCTAssertEqual(try readMeta().transcription?.status, .failed)
        XCTAssertEqual(try readTranscript().chunks.filter(\.done).count, 2)

        let second = FakeEngine()
        second.speech = [(0, 600_000)]
        let transcript = try job(second).run()

        XCTAssertEqual(second.requests.count, 2, "готовые чанки system не расшифровываются повторно")
        XCTAssertTrue(transcript.isComplete)
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertEqual(try readMeta().transcription?.status, .done)
    }

    func testRestartsWhenModelChanged() throws {
        try writeSession(seconds: 60)
        let first = FakeEngine(modelVersion: "old")
        first.speech = [(0, 60_000)]
        _ = try job(first).run()

        let second = FakeEngine(modelVersion: "new")
        second.speech = [(0, 60_000)]
        let transcript = try job(second).run()

        XCTAssertEqual(second.requests.count, 2)
        XCTAssertEqual(Set(transcript.segments.map(\.modelVersion)), ["new"])
    }

    func testRestartsWhenSystemModeChanged() throws {
        try writeSession(seconds: 60)
        let first = FakeEngine()
        first.speech = [(0, 60_000)]
        _ = try job(first).run()

        let second = FakeEngine()
        second.speech = [(0, 60_000)]
        let vadJob = TranscriptionJob(directory: dir, engine: second, systemVAD: true, clock: clock,
                                      loadAudio: { [unowned self] url in self.audio[url.lastPathComponent]! },
                                      align: { _ in })
        let transcript = try vadJob.run()

        XCTAssertEqual(second.requests.count, 2)
        XCTAssertTrue(transcript.systemVAD)
    }

    func testRestartFlagTranscribesEverythingAgain() throws {
        try writeSession(seconds: 60)
        let first = FakeEngine()
        first.speech = [(0, 60_000)]
        _ = try job(first).run()

        let second = FakeEngine()
        second.speech = [(0, 60_000)]
        _ = try job(second).run(restart: true)

        XCTAssertEqual(second.requests.count, 2)
    }

    func testMicOutsideLoudSpeechIsSilenced() throws {
        try writeSession(seconds: 60)
        // 0–10 с тихий шум, 20–40 с громкая речь
        var mic = [Float](repeating: 0.005, count: 60 * rate)
        for i in 20 * rate ..< 40 * rate { mic[i] = 0.3 }
        audio["mic.caf"] = mic
        let engine = FakeEngine()
        engine.speech = [(0, 10_000), (20_000, 40_000)]

        _ = try job(engine).run()

        // system целиком, затем одно окно mic: речь 20–40 с плюс 200 мс с каждой стороны
        XCTAssertEqual(engine.requests.count, 2)
        let micRequest = engine.requests[1]
        XCTAssertEqual(micRequest.samples.count, 20_400 * rate / 1000)
        XCTAssertEqual(micRequest.samples[0], 0, "шум перед речью обнулён")
        XCTAssertEqual(micRequest.samples[10 * rate], 0.3)
        XCTAssertEqual(try readMeta().transcription?.micSpeechSeconds ?? 0, 20, accuracy: 0.01)
    }

    func testMicWithoutSpeechIsNotTranscribed() throws {
        try writeSession(seconds: 60)
        let engine = FakeEngine()
        engine.speech = []

        let transcript = try job(engine).run()

        XCTAssertEqual(engine.requests.count, 1, "только system")
        XCTAssertTrue(transcript.isComplete)
    }

    func testPausesAreNotTranscribed() throws {
        // отрезки 0–100 с и 200–400 с, между ними пауза (в файлах тишина)
        let seg1 = RecordingSegment(index: 0, startHostTime: HostInstant(ticks: 0, clock: clock),
                                    endHostTime: HostInstant(ticks: clock.ticks(seconds: 100), clock: clock),
                                    system: FrameRange(startFrame: 0, endFrame: 100 * 48_000),
                                    mic: FrameRange(startFrame: 0, endFrame: 100 * 24_000))
        let seg2 = RecordingSegment(index: 1, startHostTime: HostInstant(ticks: clock.ticks(seconds: 200), clock: clock),
                                    endHostTime: HostInstant(ticks: clock.ticks(seconds: 400), clock: clock),
                                    system: FrameRange(startFrame: 200 * 48_000, endFrame: 400 * 48_000),
                                    mic: FrameRange(startFrame: 200 * 24_000, endFrame: 400 * 24_000))
        try writeSession(seconds: 400, segments: [seg1, seg2])
        let engine = FakeEngine()
        engine.speech = [(0, 400_000)]

        let transcript = try job(engine).run()

        let system = transcript.chunks.filter { $0.track == .system }
        XCTAssertEqual(system.map(\.startSample), [0, 200 * rate])
        XCTAssertEqual(system.map(\.endSample), [100 * rate, 400 * rate])
        XCTAssertEqual(try readMeta().transcription?.audioSeconds ?? 0, 600, accuracy: 0.01)
    }

    func testMicSegmentsKeepTrackTimeAcrossWindows() throws {
        try writeSession(seconds: 120)
        let engine = FakeEngine()
        engine.speech = [(10_000, 12_000), (80_000, 85_000)]

        let transcript = try job(engine).run()

        // реплика движка начинается через 1 с от начала окна; окна начинаются на 9.8 и 79.8 с
        let mic = transcript.segments.filter { $0.track == .mic }
        XCTAssertEqual(mic.map(\.startMs), [10_800, 80_800])
        XCTAssertEqual(mic.map(\.id), ["mic-0-0", "mic-0-1"])
    }

    func testSystemVADOptionTranscribesOnlySpeechWindows() throws {
        try writeSession(seconds: 120)
        let engine = FakeEngine()
        engine.speech = [(10_000, 12_000)]
        let job = TranscriptionJob(directory: dir, engine: engine, systemVAD: true, clock: clock,
                                   loadAudio: { [unowned self] url in self.audio[url.lastPathComponent]! },
                                   align: { _ in })

        _ = try job.run()

        XCTAssertEqual(engine.requests.map(\.samples.count), [2_400 * 16, 2_400 * 16])
    }

    func testRefusesSessionThatIsStillRecording() throws {
        try writeSession(seconds: 60, status: .recording)

        XCTAssertThrowsError(try job(FakeEngine()).run()) {
            XCTAssertEqual($0 as? TranscriptionError, .stillRecording)
        }
    }

    func testRunsAlignmentFirstWhenMissing() throws {
        try writeSession(seconds: 60, aligned: false)
        var aligned = false
        let alignment = alignment()
        let align: (URL) throws -> Void = { [root] dir in
            aligned = true
            let store = SessionStore(root: root!)
            var meta = try store.read(from: dir)
            meta.alignment = alignment
            try store.write(meta, to: dir)
        }

        let transcript = try job(FakeEngine(), align: align).run()

        XCTAssertTrue(aligned)
        XCTAssertEqual(transcript.segments.first { $0.track == .system }?.startMs, 1_115)
    }

    func testRefusesWhenAnotherLiveProcessHoldsTheLock() throws {
        try writeSession(seconds: 60)
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(to: dir.appendingPathComponent(TranscriptionJob.lockFileName), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try job(FakeEngine()).run()) {
            XCTAssertEqual($0 as? TranscriptionError, .alreadyRunning(pid))
        }
    }

    func testTakesOverStaleLock() throws {
        try writeSession(seconds: 60)
        try "999999".write(to: dir.appendingPathComponent(TranscriptionJob.lockFileName), atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try job(FakeEngine()).run())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(TranscriptionJob.lockFileName).path))
    }
}
