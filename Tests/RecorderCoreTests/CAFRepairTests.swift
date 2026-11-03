import XCTest
import AVFoundation
@testable import RecorderCore

final class CAFRepairTests: XCTestCase {
    var dir: URL!
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Пишет frames кадров и возвращает копию файла, снятую пока AVAudioFile ещё открыт
    /// (так файл выглядит после kill -9).
    private func snapshotOfOpenFile(frames: AVAudioFrameCount) throws -> URL {
        let url = dir.appendingPathComponent("live.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        let copy = dir.appendingPathComponent("crashed.caf")
        try FileManager.default.copyItem(at: url, to: copy)
        _ = file   // закрывается только после копирования
        return copy
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
    }

    func testOpenFileGetsExplicitDataSize() throws {
        let crashed = try snapshotOfOpenFile(frames: 24_000)

        let result = try CAFRepair.repair(url: crashed)

        XCTAssertTrue(result.changed)
        XCTAssertNil(result.headerFramesBefore)        // было -1, «до конца файла»
        XCTAssertEqual(result.frames, 24_000)
        XCTAssertEqual(try AVAudioFile(forReading: crashed).length, 24_000)
    }

    func testDryRunReportsProblemWithoutChangingFile() throws {
        let crashed = try snapshotOfOpenFile(frames: 2_400)
        let before = try Data(contentsOf: crashed)

        let result = try CAFRepair.repair(url: crashed, dryRun: true)

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.frames, 2_400)
        XCTAssertEqual(try Data(contentsOf: crashed), before)
    }

    func testTrailingPartialFrameIsTruncated() throws {
        let crashed = try snapshotOfOpenFile(frames: 2_400)
        let handle = try FileHandle(forWritingTo: crashed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3]))   // 3 байта из 4-байтного кадра
        try handle.close()

        let result = try CAFRepair.repair(url: crashed)

        XCTAssertEqual(result.frames, 2_400)
        XCTAssertEqual(result.truncatedBytes, 3)
        XCTAssertEqual(try AVAudioFile(forReading: crashed).length, 2_400)
    }

    func testHeaderClaimingMoreDataThanFileHasIsFixed() throws {
        let url = dir.appendingPathComponent("closed.caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            try file.write(from: buffer)
        }
        // обрезаем хвост: в заголовке 4800 кадров, на диске 4000
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(try fileSize(url) - 800 * 4))
        try handle.close()

        let result = try CAFRepair.repair(url: url)

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.headerFramesBefore, 4_800)
        XCTAssertEqual(result.frames, 4_000)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 4_000)
    }

    func testProperlyClosedFileIsLeftUntouched() throws {
        let url = dir.appendingPathComponent("closed.caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            try file.write(from: buffer)
        }
        let before = try Data(contentsOf: url)

        let result = try CAFRepair.repair(url: url)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.frames, 4_800)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testNonCAFFileThrows() throws {
        let url = dir.appendingPathComponent("junk.caf")
        try Data("not a caf".utf8).write(to: url)

        XCTAssertThrowsError(try CAFRepair.repair(url: url))
    }
}
