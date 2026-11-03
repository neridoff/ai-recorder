import Foundation
import AVFoundation
import AudioToolbox

public enum CompressionState: String, Codable, Sendable {
    case done, failed
}

/// Одна сжатая дорожка: что было и что стало (ADR-005).
public struct CompressedTrack: Codable, Equatable, Sendable {
    public var track: String
    public var originalFile: String
    public var file: String
    /// HE-AAC или AAC-LC (если HE-AAC недоступен для частоты дорожки).
    public var codec: String
    public var bitRate: Int
    public var originalBytes: Int64
    public var bytes: Int64
}

/// Блок compression в session.json (E5, ADR-005, схема 5).
public struct CompressionRecord: Codable, Equatable, Sendable {
    public var status: CompressionState
    public var finishedAt: Date
    public var tracks: [CompressedTrack]
    public var processingSeconds: Double
    public var error: String?

    public init(status: CompressionState, finishedAt: Date, tracks: [CompressedTrack],
                processingSeconds: Double, error: String? = nil) {
        self.status = status
        self.finishedAt = finishedAt
        self.tracks = tracks
        self.processingSeconds = processingSeconds
        self.error = error
    }
}

public enum AudioStorageError: LocalizedError, Equatable {
    case cancelled
    case lengthMismatch(String, Int64, Int64)
    case noEncoder(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "обслуживание архива отменено"
        case .lengthMismatch(let f, let expected, let got): return "\(f): после сжатия \(got) кадров вместо \(expected)"
        case .noEncoder(let why): return "нет кодера AAC: \(why)"
        }
    }
}

/// Сжатие дорожек после обработки (FR-11, NFR-05, ADR-005): system.caf и mic.caf (Float32 PCM)
/// заменяются на system.m4a и mic.m4a (HE-AAC, около 40 + 24 кбит/с). Частота и число каналов
/// не меняются, длина в кадрах тоже, поэтому таймкоды, anchors и сведение остаются верны.
/// mixed.m4a (AAC 128 кбит/с от выравнивания) перекодируется в HE-AAC 40 кбит/с на месте.
public enum AudioCompression {
    /// Целевой битрейт на дорожку: стерео (system) и моно (mic), вместе около 64 кбит/с (NFR-05).
    public static let stereoBitRate = 40_000
    public static let monoBitRate = 24_000
    public static let compressedExtension = "m4a"
    /// Допуск длины после декодирования: один пакет AAC. На практике длина совпадает до кадра.
    static let lengthTolerance: Int64 = 2048
    static let readFrames: AVAudioFrameCount = 65_536

    public typealias Encoder = (_ source: URL, _ destination: URL, _ isCancelled: () -> Bool) throws -> (codec: String, bitRate: Int)

    /// Сжимать нужно обработанную запись, у которой ещё нет удачного сжатия и не удалено аудио.
    /// Неудачное сжатие повторяется при следующей проверке.
    public static func needsCompression(_ meta: SessionMetadata) -> Bool {
        meta.isProcessed && meta.audioDeleted != true && meta.compression?.status != .done
    }

    /// Сжимает дорожки записи. Порядок для каждой дорожки: кодирование во временный
    /// `.<имя>.partial.m4a`, проверка длины, rename в `<имя>.m4a`; затем атомарная запись
    /// session.json с новыми именами; только после неё удаляются исходные .caf.
    /// При ошибке кодирования исходники остаются, временные и уже сжатые файлы убираются,
    /// ошибка пишется в compression и errors, результат возвращается со статусом failed.
    /// Отмена (новая запись или обработка) ничего не пишет и бросает `.cancelled`.
    @discardableResult
    public static func compress(directory dir: URL, store: SessionStore, now: Date = SessionMetadata.now(),
                                isCancelled: @escaping () -> Bool = { false },
                                encode: Encoder = encodeAAC) throws -> CompressionRecord {
        let lock = SessionLock(directory: dir)
        try lock.acquire()
        defer { lock.release() }

        let meta = try store.read(from: dir)
        let started = Date()
        var produced: [URL] = []
        var partials: [URL] = []
        var tracks: [CompressedTrack] = []
        let fm = FileManager.default
        do {
            var jobs: [(name: String, file: String, target: String)] = []
            for (name, track) in [("system", meta.system), ("mic", meta.mic)] {
                guard let track, (track.file as NSString).pathExtension != compressedExtension else { continue }
                jobs.append((name, track.file, "\(name).\(compressedExtension)"))
            }
            let mixed = meta.alignment?.mixFile ?? SessionAlignment.mixFileName(.m4a)
            let mixedURL = dir.appendingPathComponent(mixed)
            if (mixed as NSString).pathExtension == compressedExtension, fm.fileExists(atPath: mixedURL.path), !isHEAAC(mixedURL) {
                jobs.append(("mixed", mixed, mixed))   // уже HE-AAC (повтор после сбоя) не перекодируется
            }
            for (name, file, target) in jobs {
                let source = dir.appendingPathComponent(file)
                let partial = dir.appendingPathComponent(".\(name).partial.\(compressedExtension)")
                let final = dir.appendingPathComponent(target)
                partials.append(partial)
                try? fm.removeItem(at: partial)
                let format: (codec: String, bitRate: Int)
                do {
                    format = try encode(source, partial, isCancelled)
                } catch let error as AudioStorageError where error == .cancelled {
                    throw error
                } catch {
                    throw TrackFailure(file: file, message: error.localizedDescription)
                }
                let originalBytes = fileSize(source)
                if target == file {
                    // mixed: rename поверх исходника атомарно заменяет его
                    _ = try fm.replaceItemAt(final, withItemAt: partial)
                } else {
                    if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }   // остаток прерванной попытки
                    try fm.moveItem(at: partial, to: final)
                    produced.append(final)
                }
                tracks.append(CompressedTrack(track: name, originalFile: file, file: target,
                                              codec: format.codec, bitRate: format.bitRate,
                                              originalBytes: originalBytes, bytes: fileSize(final)))
            }
            var updated = try store.read(from: dir)
            for t in tracks {
                switch t.track {
                case "system": updated.system?.file = t.file
                case "mic": updated.mic?.file = t.file
                default: break   // mixed сжат на месте, имя в alignment прежнее
                }
            }
            let record = CompressionRecord(status: .done, finishedAt: now, tracks: tracks,
                                           processingSeconds: Date().timeIntervalSince(started))
            updated.compression = record
            stamp(&updated, now: now)
            try store.write(updated, to: dir)
            // session.json уже указывает на сжатые файлы: исходники больше не нужны
            for t in tracks where t.originalFile != t.file { try? fm.removeItem(at: dir.appendingPathComponent(t.originalFile)) }
            return record
        } catch {
            for url in partials + produced { try? fm.removeItem(at: url) }
            if let e = error as? AudioStorageError, e == .cancelled { throw e }
            let message = (error as? TrackFailure).map { "\($0.file): \($0.message)" } ?? error.localizedDescription
            var updated = try store.read(from: dir)
            let record = CompressionRecord(status: .failed, finishedAt: now, tracks: [],
                                           processingSeconds: Date().timeIntervalSince(started), error: message)
            updated.compression = record
            updated.errors.append(SessionErrorRecord(at: now, source: "compression", message: message))
            stamp(&updated, now: now)
            try store.write(updated, to: dir)
            return record
        }
    }

    /// Убирает исходник, оставшийся после сбоя между записью session.json и удалением .caf.
    public static func removeLeftoverOriginals(in dir: URL, meta: SessionMetadata) {
        guard let record = meta.compression, record.status == .done else { return }
        let current = Set([meta.system?.file, meta.mic?.file].compactMap { $0 })
        for t in record.tracks where t.originalFile != t.file && !current.contains(t.originalFile) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(t.originalFile))
        }
    }

    /// Кодер по умолчанию: AVAudioFile, HE-AAC в m4a, без сети (NFR-01). Длина проверяется чтением результата.
    public static func encodeAAC(source: URL, destination: URL, isCancelled: () -> Bool) throws -> (codec: String, bitRate: Int) {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let target = channels >= 2 ? stereoBitRate : monoBitRate
        let choice = try chooseCodec(sampleRate: format.sampleRate, channels: channels, target: target)
        let settings: [String: Any] = [AVFormatIDKey: choice.id, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: choice.bitRate]
        // отдельная область видимости: AVAudioFile дописывает файл при освобождении
        try autoreleasepool {
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames)!
            while input.framePosition < input.length {
                if isCancelled() { throw AudioStorageError.cancelled }
                try input.read(into: buffer)
                try output.write(from: buffer)
            }
        }
        let length = try AVAudioFile(forReading: destination).length
        guard abs(length - input.length) <= lengthTolerance else {
            throw AudioStorageError.lengthMismatch(source.lastPathComponent, input.length, length)
        }
        return (choice.name, choice.bitRate)
    }

    /// HE-AAC с ближайшим допустимым битрейтом не выше целевого; если HE-AAC для такой частоты нет, AAC-LC.
    static func chooseCodec(sampleRate: Double, channels: Int, target: Int) throws -> (id: AudioFormatID, name: String, bitRate: Int) {
        for (id, name) in [(kAudioFormatMPEG4AAC_HE, "HE-AAC"), (kAudioFormatMPEG4AAC, "AAC-LC")] {
            let rates = applicableBitRates(id, sampleRate: sampleRate, channels: channels)
            guard let lowest = rates.min() else { continue }
            return (id, name, rates.filter { $0 <= target }.max() ?? lowest)
        }
        throw AudioStorageError.noEncoder("\(Int(sampleRate)) Гц, каналов \(channels)")
    }

    static func applicableBitRates(_ id: AudioFormatID, sampleRate: Double, channels: Int) -> [Int] {
        var src = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                              mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                              mBitsPerChannel: 32, mReserved: 0)
        var dst = AudioStreamBasicDescription()
        dst.mFormatID = id
        dst.mSampleRate = sampleRate
        dst.mChannelsPerFrame = UInt32(channels)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&src, &dst, &converter) == noErr, let converter else { return [] }
        defer { AudioConverterDispose(converter) }
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
              size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr else { return [] }
        return ranges.map { Int($0.mMinimum) }.filter { $0 > 0 }
    }

    static func isHEAAC(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let id = file.fileFormat.streamDescription.pointee.mFormatID
        return id == kAudioFormatMPEG4AAC_HE || id == kAudioFormatMPEG4AAC_HE_V2
    }

    static func stamp(_ meta: inout SessionMetadata, now: Date) {
        meta.schemaVersion = max(meta.schemaVersion, SessionMetadata.currentSchemaVersion)
        meta.keepAudio = meta.keepAudio ?? false   // поле появляется в файле, его можно поменять вручную (FR-13)
        meta.updatedAt = now
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private struct TrackFailure: Error {
        var file: String
        var message: String
    }
}
