import XCTest
import AVFoundation
@testable import RecorderCore

/// Источник звука, которым управляет тест.
final class FakeSource: AudioCaptureSource, @unchecked Sendable {
    let name: String
    var deviceName: String
    var deviceNameAfterStart: String?
    let nominalSampleRate: Double
    let nominalChannels: Int
    var startError: Error?
    private(set) var started = false
    private(set) var stopped = false
    private(set) var startCount = 0
    private var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?
    private var onFailure: ((String) -> Void)?

    init(name: String, rate: Double, channels: Int) {
        self.name = name
        self.deviceName = "Fake \(name)"
        self.nominalSampleRate = rate
        self.nominalChannels = channels
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void, onFailure: @escaping (String) -> Void) async throws {
        if let startError { throw startError }
        self.onBuffer = onBuffer
        self.onFailure = onFailure
        if let deviceNameAfterStart { deviceName = deviceNameAfterStart }
        started = true
        stopped = false
        startCount += 1
    }

    func stop() async { stopped = true }

    func emit(frames: AVAudioFrameCount, hostTime: UInt64) {
        let format = AVAudioFormat(standardFormatWithSampleRate: nominalSampleRate, channels: AVAudioChannelCount(nominalChannels))!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        onBuffer?(b, hostTime)
    }

    func fail(_ message: String) { onFailure?(message) }
}

final class RecordingSessionTests: XCTestCase {
    var root: URL!
    var store: SessionStore!
    let clock = HostClock(numer: 1000, denom: 1)   // 1 тик = 1 мкс
    var system: FakeSource!
    var mic: FakeSource!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(root: root)
        system = FakeSource(name: "system", rate: 48_000, channels: 2)
        mic = FakeSource(name: "mic", rate: 24_000, channels: 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(interval: TimeInterval = 5) -> RecordingSession {
        RecordingSession(store: store, system: system, mic: mic, clock: clock, metadataInterval: interval)
    }

    func testStartWritesSessionJSONWithRecordingStatusBeforeAnyAudio() async throws {
        let session = makeSession()

        try await session.start(startPressedHostTime: 1_000_000)

        let meta = try store.read(from: session.directory!)
        XCTAssertEqual(meta.status, .recording)
        XCTAssertEqual(meta.system?.file, "system.caf")
        XCTAssertEqual(meta.mic?.sampleRate, 24_000)
        XCTAssertEqual(meta.mic?.deviceName, "Fake mic")
        XCTAssertEqual(meta.startPressedHostTime?.ticks, 1_000_000)
        XCTAssertTrue(system.started && mic.started)
        _ = await session.stop()
    }

    func testMultipleVoicesFlagIsWrittenToSessionJSON() async throws {
        let session = makeSession()
        try await session.start(startPressedHostTime: 1_000_000)

        session.setMultipleVoices(true)
        let meta = await session.stop()

        XCTAssertEqual(meta.multipleVoices, true)
        XCTAssertEqual(try store.read(from: session.directory!).multipleVoices, true)
    }

    func testStopProducesCompletedSessionWithOffsetLatencyAndFiles() async throws {
        let session = makeSession()
        try await session.start(startPressedHostTime: 1_000_000)

        mic.emit(frames: 2_400, hostTime: 1_200_000)       // первый сэмпл микрофона через 200 мс
        system.emit(frames: 4_800, hostTime: 1_335_000)    // системный звук на 135 мс позже
        let meta = await session.stop()

        XCTAssertEqual(meta.status, .completed)
        XCTAssertNotNil(meta.stoppedAt)
        XCTAssertEqual(meta.startOffsetMs!, -135, accuracy: 1e-6)
        XCTAssertEqual(meta.mic!.startLatencyMs!, 200, accuracy: 1e-6)
        XCTAssertEqual(meta.system!.framesWritten, 4_800)
        XCTAssertEqual(meta.mic!.durationSeconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(try store.read(from: session.directory!), meta)
        XCTAssertTrue(system.stopped && mic.stopped)
        XCTAssertEqual(try AVAudioFile(forReading: session.directory!.appendingPathComponent("mic.caf")).length, 2_400)
    }

    func testPauseAndResumeKeepRealTimeAndRecordSegments() async throws {
        let session = makeSession()
        try await session.start(startPressedHostTime: 1_000_000)
        system.emit(frames: 4_800, hostTime: 1_000_000)    // 0,1 с
        mic.emit(frames: 2_400, hostTime: 1_000_000)

        await session.pause(pressedHostTime: 1_100_000)
        XCTAssertTrue(system.stopped && mic.stopped, "во время паузы захват остановлен")
        XCTAssertTrue(session.isPaused)

        try await session.resume(pressedHostTime: 3_100_000)   // пауза 2 с
        system.emit(frames: 4_800, hostTime: 3_100_000)
        mic.emit(frames: 2_400, hostTime: 3_100_000)
        let meta = await session.stop()

        XCTAssertEqual(system.startCount, 2)
        XCTAssertEqual(meta.status, .completed)
        XCTAssertEqual(meta.system?.framesWritten, 4_800 + 96_000 + 4_800)
        XCTAssertEqual(meta.mic?.framesWritten, 2_400 + 48_000 + 2_400)
        XCTAssertEqual(meta.system?.gaps, [], "пауза не считается разрывом")
        let segments = try XCTUnwrap(meta.segments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startHostTime.ticks, 1_000_000)
        XCTAssertEqual(segments[0].endHostTime?.ticks, 1_100_000)
        XCTAssertEqual(segments[0].system, FrameRange(startFrame: 0, endFrame: 4_800))
        XCTAssertEqual(segments[0].mic, FrameRange(startFrame: 0, endFrame: 2_400))
        XCTAssertEqual(segments[1].startHostTime.ticks, 3_100_000)
        XCTAssertNotNil(segments[1].endHostTime)
        XCTAssertEqual(segments[1].system, FrameRange(startFrame: 100_800, endFrame: 105_600))
        XCTAssertEqual(segments[1].mic, FrameRange(startFrame: 50_400, endFrame: 52_800))
        XCTAssertEqual(try store.read(from: session.directory!).segments, segments)
        XCTAssertEqual(try AVAudioFile(forReading: session.directory!.appendingPathComponent("system.caf")).length, 105_600)
    }

    func testStopWhilePausedKeepsLastSegmentClosedAtPause() async throws {
        let session = makeSession()
        try await session.start(startPressedHostTime: 1_000_000)
        system.emit(frames: 4_800, hostTime: 1_000_000)
        mic.emit(frames: 2_400, hostTime: 1_000_000)

        await session.pause(pressedHostTime: 1_100_000)
        let meta = await session.stop()

        XCTAssertEqual(meta.segments?.count, 1)
        XCTAssertEqual(meta.segments?[0].endHostTime?.ticks, 1_100_000)
        XCTAssertEqual(meta.system?.framesWritten, 4_800)
    }

    func testSessionWithoutPauseHasOneSegment() async throws {
        let session = makeSession()
        try await session.start(startPressedHostTime: 1_000_000)
        system.emit(frames: 4_800, hostTime: 1_000_000)

        let meta = await session.stop()

        XCTAssertEqual(meta.segments?.count, 1)
        XCTAssertEqual(meta.segments?[0].system, FrameRange(startFrame: 0, endFrame: 4_800))
        XCTAssertNil(meta.segments?[0].mic, "mic не дал ни одного буфера")
    }

    func testDeviceNameKnownOnlyAfterStartIsRecorded() async throws {
        system.deviceNameAfterStart = "ScreenCaptureKit, дисплей 1"
        let session = makeSession()

        try await session.start(startPressedHostTime: 0)
        let meta = await session.stop()

        XCTAssertEqual(meta.system?.deviceName, "ScreenCaptureKit, дисплей 1")
    }

    func testMetadataIsFlushedPeriodicallyWhileRecording() async throws {
        let session = makeSession(interval: 0.05)
        try await session.start(startPressedHostTime: 0)

        system.emit(frames: 4_800, hostTime: 10_000)
        try await Task.sleep(nanoseconds: 300_000_000)

        let meta = try store.read(from: session.directory!)
        XCTAssertEqual(meta.status, .recording)
        XCTAssertEqual(meta.system?.framesWritten, 4_800)
        _ = await session.stop()
    }

    func testRuntimeSourceFailureIsRecordedInMetadata() async throws {
        let session = makeSession()
        try await session.start(startPressedHostTime: 0)

        mic.fail("сменилось устройство ввода")
        let meta = await session.stop()

        XCTAssertTrue(meta.errors.contains { $0.source == "mic" && $0.message.contains("устройство") })
    }

    func testEmptyTrackIsReportedAtStop() async throws {
        let session = makeSession()
        try await session.start(startPressedHostTime: 0)

        system.emit(frames: 480, hostTime: 10_000)
        let meta = await session.stop()

        XCTAssertEqual(meta.status, .completed)
        XCTAssertTrue(meta.errors.contains { $0.source == "mic" && $0.message.contains("нет данных") })
    }

    func testStartFailureStopsOtherSourceAndMarksSessionFailed() async throws {
        system.startError = CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "нет разрешения на запись экрана"])
        let session = makeSession()

        do {
            try await session.start(startPressedHostTime: 0)
            XCTFail("start должен бросить ошибку")
        } catch {}

        let meta = try store.read(from: session.directory!)
        XCTAssertEqual(meta.status, .failed)
        XCTAssertTrue(meta.errors.contains { $0.message.contains("запись экрана") })
        XCTAssertTrue(mic.stopped)
    }
}
