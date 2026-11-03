import XCTest
import AVFoundation
@testable import RecorderCore

final class TrackWriterTests: XCTestCase {
    var dir: URL!
    let clock = HostClock(numer: 1000, denom: 1)   // 1 тик = 1 мкс

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func buffer(rate: Double = 48_000, channels: AVAudioChannelCount = 2, frames: AVAudioFrameCount, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) { b.floatChannelData![ch][i] = value }
        }
        return b
    }

    func testWritesBuffersAndReportsTimeline() throws {
        let url = dir.appendingPathComponent("system.caf")
        let writer = TrackWriter(url: url, name: "system", clock: clock)

        writer.append(buffer(frames: 480), hostTime: 2_000_000)
        writer.append(buffer(frames: 480), hostTime: 2_010_000)
        let state = writer.finish()

        XCTAssertEqual(state.firstSampleHostTime?.ticks, 2_000_000)
        XCTAssertEqual(state.framesWritten, 960)
        XCTAssertEqual(state.sampleRate, 48_000)
        XCTAssertEqual(state.channels, 2)
        XCTAssertTrue(state.errors.isEmpty)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 960)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
    }

    func testGapIsFilledWithSilenceInTheFile() throws {
        let url = dir.appendingPathComponent("mic.caf")
        let writer = TrackWriter(url: url, name: "mic", clock: clock)

        writer.append(buffer(rate: 24_000, channels: 1, frames: 240), hostTime: 0)
        writer.append(buffer(rate: 24_000, channels: 1, frames: 240), hostTime: 110_000)   // дыра 100 мс
        let state = writer.finish()

        XCTAssertEqual(state.gaps.count, 1)
        XCTAssertEqual(state.framesWritten, 240 + 2_400 + 240)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 2_880)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_880)!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][239], 0.25)
        XCTAssertEqual(read.floatChannelData![0][1_000], 0)        // тишина
        XCTAssertEqual(read.floatChannelData![0][2_640], 0.25)
    }

    func testCallerMayReuseBufferAfterAppend() throws {
        let url = dir.appendingPathComponent("mic.caf")
        let writer = TrackWriter(url: url, name: "mic", clock: clock)
        let reused = buffer(rate: 24_000, channels: 1, frames: 240, value: 0.5)

        writer.append(reused, hostTime: 0)
        reused.floatChannelData![0][0] = -1   // аудиопоток переиспользует буфер
        _ = writer.finish()

        let file = try AVAudioFile(forReading: url)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 240)!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][0], 0.5)
    }

    func testFileCreationFailureIsReportedNotSwallowed() throws {
        let url = dir.appendingPathComponent("missing-dir/system.caf")
        var reported: [String] = []
        let writer = TrackWriter(url: url, name: "system", clock: clock) { reported.append($0) }

        writer.append(buffer(frames: 480), hostTime: 0)
        let state = writer.finish()

        XCTAssertEqual(state.errors.count, 1)
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported[0].contains("system"), reported[0])
    }

    func testFormatChangeMidStreamIsReportedAsError() throws {
        let url = dir.appendingPathComponent("mic.caf")
        let writer = TrackWriter(url: url, name: "mic", clock: clock)

        writer.append(buffer(rate: 24_000, channels: 1, frames: 240), hostTime: 0)
        writer.append(buffer(rate: 48_000, channels: 1, frames: 480), hostTime: 10_000)   // сменилось устройство
        let state = writer.finish()

        XCTAssertEqual(state.framesWritten, 240)
        XCTAssertEqual(state.errors.count, 1)
        XCTAssertTrue(state.errors[0].contains("формат"), state.errors[0])
    }

    func testAppendAfterFinishIsIgnored() throws {
        let url = dir.appendingPathComponent("mic.caf")
        let writer = TrackWriter(url: url, name: "mic", clock: clock)
        writer.append(buffer(rate: 24_000, channels: 1, frames: 240), hostTime: 0)
        _ = writer.finish()

        writer.append(buffer(rate: 24_000, channels: 1, frames: 240), hostTime: 10_000)

        XCTAssertEqual(writer.snapshot().framesWritten, 240)
    }
}
