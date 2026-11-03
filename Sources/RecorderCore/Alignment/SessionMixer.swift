import Foundation
import AVFoundation

public enum MixFormat: String, Sendable, CaseIterable {
    /// AAC 48 кГц стерео, для прослушивания.
    case m4a
    /// Float32 PCM без потерь, для анализа и тестов.
    case caf

    public var fileExtension: String { rawValue }

    func settings(rate: Double) -> [String: Any] {
        switch self {
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        case .caf:
            // в файле CAF данные чередуются; non-interleaved — только формат буферов при записи
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        }
    }
}

public enum MixError: LocalizedError, Equatable {
    case noTracks
    case missingFirstSample(String)
    case cannotRead(String, String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .noTracks: return "в session.json нет ни одной дорожки"
        case .missingFirstSample(let t): return "\(t): нет firstSampleHostTime, выравнивать не по чему"
        case .cannotRead(let f, let why): return "\(f) не читается: \(why)"
        case .cannotWrite(let why): return "не удалось записать сведение: \(why)"
        }
    }
}

public struct MixResult: Sendable {
    public var plan: MixPlan
    public var output: URL
    public var frames: Int64
    public var clippedSamples: Int
}

/// Сводит system и mic в один стереофайл по плану MixPlan. Исходные файлы только читаются.
/// Пишет во временный файл рядом и переименовывает в конце, чтобы при ошибке
/// не оставить обрезанный output.
public enum SessionMixer {
    public static let outputRate = 48_000.0
    static let chunkFrames = 48_000

    public static func mix(sessionDirectory dir: URL, metadata meta: SessionMetadata,
                           output: URL, format: MixFormat) throws -> MixResult {
        let clock = HostClock(numer: meta.hostTimebase.numer, denom: meta.hostTimebase.denom)
        guard meta.system != nil || meta.mic != nil else { throw MixError.noTracks }

        func planTrack(_ t: TrackMetadata?, _ label: String) throws -> MixPlan.Track? {
            guard let t else { return nil }
            guard let first = t.firstSampleHostTime else { throw MixError.missingFirstSample(label) }
            return MixPlan.Track(firstSampleTicks: first.ticks, sampleRate: t.sampleRate, frames: t.framesWritten)
        }
        let plan = MixPlan(system: try planTrack(meta.system, "system"),
                           mic: try planTrack(meta.mic, "mic"),
                           outputRate: outputRate, clock: clock)

        let system = try meta.system.map { try AlignedSource(url: dir.appendingPathComponent($0.file),
                                                             leadFrames: plan.systemLeadFrames, outputRate: outputRate) }
        let mic = try meta.mic.map { try AlignedSource(url: dir.appendingPathComponent($0.file),
                                                       leadFrames: plan.micLeadFrames, outputRate: outputRate) }

        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).partial.\(format.fileExtension)")
        try? FileManager.default.removeItem(at: partial)
        var clipped = 0
        do {
            // отдельная область видимости: AVAudioFile закрывается и дописывает заголовок при освобождении
            try autoreleasepool {
                let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
                let out = try AVAudioFile(forWriting: partial, settings: format.settings(rate: outputRate),
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(chunkFrames))!
                var written: Int64 = 0
                while written < plan.totalFrames {
                    let n = Int(min(Int64(chunkFrames), plan.totalFrames - written))
                    let block = MixKernel.mix(system: try system?.read(frames: n), mic: try mic?.read(frames: n), frames: n)
                    clipped += block.clippedSamples
                    buffer.frameLength = AVAudioFrameCount(n)
                    block.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
                    block.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: n) }
                    try out.write(from: buffer)
                    written += Int64(n)
                }
            }
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.moveItem(at: partial, to: output)
        } catch let error as MixError {
            try? FileManager.default.removeItem(at: partial)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw MixError.cannotWrite(error.localizedDescription)
        }
        return MixResult(plan: plan, output: output, frames: plan.totalFrames, clippedSamples: clipped)
    }
}

/// Дорожка на шкале сведения: сначала leadFrames тишины, затем содержимое файла
/// в частоте outputRate (с ресемплингом, если частота файла другая), после конца — тишина.
final class AlignedSource {
    private let file: AVAudioFile
    private let name: String
    private let channels: Int
    private var lead: Int64
    private let converter: AVAudioConverter?
    private let readBuffer: AVAudioPCMBuffer
    private let convertBuffer: AVAudioPCMBuffer?
    private var exhausted = false
    /// Уже прочитанные, но ещё не отданные кадры (в частоте выхода), по каналам.
    private var pending: [[Float]]

    init(url: URL, leadFrames: Int64, outputRate: Double) throws {
        name = url.lastPathComponent
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MixError.cannotRead(name, error.localizedDescription)
        }
        let inFormat = file.processingFormat
        channels = Int(inFormat.channelCount)
        lead = leadFrames
        pending = Array(repeating: [], count: channels)
        readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(SessionMixer.chunkFrames))!
        if inFormat.sampleRate != outputRate {
            let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: inFormat.channelCount)!
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            convertBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(SessionMixer.chunkFrames))
        } else {
            converter = nil
            convertBuffer = nil
        }
    }

    /// frames кадров на шкале сведения, по каналам.
    func read(frames: Int) throws -> [[Float]] {
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        var pos = 0
        if lead > 0 {
            let k = Int(min(lead, Int64(frames)))
            lead -= Int64(k)
            pos = k
        }
        while pending[0].count < frames - pos, !exhausted {
            guard let buffer = try nextChunk(), buffer.frameLength > 0 else { exhausted = true; break }
            for ch in 0..<channels {
                pending[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch],
                                                                   count: Int(buffer.frameLength)))
            }
        }
        let n = min(frames - pos, pending[0].count)
        for ch in 0..<channels {
            out[ch].replaceSubrange(pos..<pos + n, with: pending[ch][0..<n])
            pending[ch].removeFirst(n)
        }
        return out
    }

    /// Следующая порция в частоте выхода; nil в конце файла.
    private func nextChunk() throws -> AVAudioPCMBuffer? {
        guard let converter, let convertBuffer else {
            guard file.framePosition < file.length else { return nil }
            do {
                try file.read(into: readBuffer)
            } catch {
                throw MixError.cannotRead(name, error.localizedDescription)
            }
            return readBuffer
        }
        convertBuffer.frameLength = 0
        var readError: Error?
        var convertError: NSError?
        let status = converter.convert(to: convertBuffer, error: &convertError) { _, inputStatus in
            if readError != nil || self.file.framePosition >= self.file.length {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try self.file.read(into: self.readBuffer)
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return self.readBuffer
        }
        if let readError { throw MixError.cannotRead(name, readError.localizedDescription) }
        switch status {
        case .error:
            throw MixError.cannotRead(name, convertError?.localizedDescription ?? "ошибка ресемплинга")
        case .endOfStream where convertBuffer.frameLength == 0:
            return nil
        default:
            return convertBuffer
        }
    }
}
