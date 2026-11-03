import XCTest
import AVFoundation
@testable import RecorderCore

final class TrackAudioLoaderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Каналы заполняются постоянными значениями: так видно, как они сводятся в моно.
    private func writeConstant(_ name: String, rate: Double, values: [Float], seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(values.count))!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for (ch, v) in values.enumerated() {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = v }
        }
        try file.write(from: buffer)
        return url
    }

    func testStereo48kBecomesMono16kAverageOfChannels() throws {
        let url = try writeConstant("system.caf", rate: 48_000, values: [0.2, 0.6], seconds: 2)

        let samples = try TrackAudioLoader.loadMono16k(url: url)

        XCTAssertEqual(samples.count, 32_000, accuracy: 16)
        XCTAssertEqual(samples[16_000], 0.4, accuracy: 0.01)
    }

    func testMono24kIsResampledTo16k() throws {
        let url = try writeConstant("mic.caf", rate: 24_000, values: [0.5], seconds: 3)

        let samples = try TrackAudioLoader.loadMono16k(url: url)

        XCTAssertEqual(samples.count, 48_000, accuracy: 16)
        XCTAssertEqual(samples[24_000], 0.5, accuracy: 0.01)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try TrackAudioLoader.loadMono16k(url: dir.appendingPathComponent("nope.caf")))
    }
}
