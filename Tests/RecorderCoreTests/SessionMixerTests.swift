import XCTest
import AVFoundation
@testable import RecorderCore

final class SessionMixerTests: XCTestCase {
    var dir: URL!
    let clock = HostClock(numer: 1000, denom: 1)   // 1 тик = 1 мкс

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// CAF с одним импульсом 0,9 в канале 0 на кадре impulseFrame.
    private func writeTrack(_ name: String, rate: Double, channels: AVAudioChannelCount,
                            frames: AVAudioFrameCount, impulseFrame: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) { memset(buffer.floatChannelData![ch], 0, Int(frames) * 4) }
        buffer.floatChannelData![0][impulseFrame] = 0.9
        try file.write(from: buffer)
    }

    private func track(_ file: String, rate: Double, channels: Int, frames: Int64, firstSeconds: Double) -> TrackMetadata {
        var t = TrackMetadata(file: file, sampleRate: rate, channels: channels, deviceName: "Test")
        t.firstSampleHostTime = HostInstant(ticks: clock.ticks(seconds: firstSeconds), clock: clock)
        t.framesWritten = frames
        t.durationSeconds = Double(frames) / rate
        return t
    }

    private func readStereo(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n)),
                Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n)))
    }

    private func peak(_ x: [Float]) -> Int {
        x.indices.max { abs(x[$0]) < abs(x[$1]) }!
    }

    func testImpulsesAtSameHostTimeLandOnSameFrameAfterAlignmentAndResampling() throws {
        // system стартовал в 100,0 с, импульс на 1,0 с файла → host 101,0 с
        try writeTrack("system.caf", rate: 48_000, channels: 2, frames: 144_000, impulseFrame: 48_000)
        // mic 24 кГц стартовал раньше, в 99,9 с, импульс на 1,1 с файла → тоже host 101,0 с
        try writeTrack("mic.caf", rate: 24_000, channels: 1, frames: 72_000, impulseFrame: 26_400)
        var meta = SessionMetadata.new(startedAt: Date(), clock: clock)
        meta.status = .completed
        meta.system = track("system.caf", rate: 48_000, channels: 2, frames: 144_000, firstSeconds: 100.0)
        meta.mic = track("mic.caf", rate: 24_000, channels: 1, frames: 72_000, firstSeconds: 99.9)
        let output = dir.appendingPathComponent("mixed.caf")

        let result = try SessionMixer.mix(sessionDirectory: dir, metadata: meta, output: output, format: .caf)

        XCTAssertEqual(result.plan.startOffsetMs!, -100, accuracy: 1e-6)
        XCTAssertEqual(result.plan.systemLeadFrames, 4_800)
        let mixed = try readStereo(output)
        XCTAssertEqual(mixed.left.count, 148_800)
        // правый канал: только микрофон (у system импульс в левом канале)
        XCTAssertEqual(peak(mixed.right), 52_800, accuracy: 24)       // ±0,5 мс
        // левый минус правый: только системный звук
        XCTAssertEqual(peak(zip(mixed.left, mixed.right).map { $0 - $1 }), 52_800, accuracy: 1)
    }

    func testSourceFilesAreNotModified() throws {
        try writeTrack("system.caf", rate: 48_000, channels: 2, frames: 4_800, impulseFrame: 10)
        try writeTrack("mic.caf", rate: 48_000, channels: 1, frames: 4_800, impulseFrame: 10)
        var meta = SessionMetadata.new(startedAt: Date(), clock: clock)
        meta.system = track("system.caf", rate: 48_000, channels: 2, frames: 4_800, firstSeconds: 10)
        meta.mic = track("mic.caf", rate: 48_000, channels: 1, frames: 4_800, firstSeconds: 10.05)
        let before = try ["system.caf", "mic.caf"].map { try Data(contentsOf: dir.appendingPathComponent($0)) }

        _ = try SessionMixer.mix(sessionDirectory: dir, metadata: meta,
                                 output: dir.appendingPathComponent("mixed.m4a"), format: .m4a)

        let after = try ["system.caf", "mic.caf"].map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        XCTAssertEqual(before, after)
        XCTAssertGreaterThan(try AVAudioFile(forReading: dir.appendingPathComponent("mixed.m4a")).length, 0)
    }

    func testMissingFirstSampleIsAnError() throws {
        try writeTrack("system.caf", rate: 48_000, channels: 2, frames: 480, impulseFrame: 0)
        var meta = SessionMetadata.new(startedAt: Date(), clock: clock)
        meta.system = TrackMetadata(file: "system.caf", sampleRate: 48_000, channels: 2, deviceName: "Test")

        XCTAssertThrowsError(try SessionMixer.mix(sessionDirectory: dir, metadata: meta,
                                                  output: dir.appendingPathComponent("mixed.caf"), format: .caf))
    }
}
