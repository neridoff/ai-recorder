import Foundation
import AVFoundation

/// Читает дорожку целиком в моно 16 кГц, как требует Whisper (ADR-004, решение 15).
/// Каналы усредняются, частота меняется через AVAudioConverter. Файл только читается.
/// 70 минут дорожки занимают около 270 МБ памяти.
public enum TrackAudioLoader {
    public static let sampleRate = 16_000.0
    static let readFrames: AVAudioFrameCount = 65_536

    public static func loadMono16k(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MixError.cannotRead(url.lastPathComponent, error.localizedDescription)
        }
        let inFormat = file.processingFormat
        let channels = Int(inFormat.channelCount)
        // Сначала моно в исходной частоте: среднее каналов считаем сами,
        // чтобы не зависеть от правил сведения каналов в AVAudioConverter.
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1)!
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let converter = AVAudioConverter(from: monoFormat, to: outFormat) else {
            throw MixError.cannotRead(url.lastPathComponent, "нет конвертера в 16 кГц")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readFrames)!
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: readFrames)!
        let outCapacity = AVAudioFrameCount(Double(readFrames) * sampleRate / inFormat.sampleRate) + 1024
        let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)!

        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * sampleRate / inFormat.sampleRate) + 1024)
        var readError: Error?

        while true {
            outBuffer.frameLength = 0
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
                if readError != nil || file.framePosition >= file.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: readBuffer)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let n = Int(readBuffer.frameLength)
                let mono = monoBuffer.floatChannelData![0]
                let src = readBuffer.floatChannelData!
                let scale = 1 / Float(channels)
                for i in 0..<n {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[ch][i] }
                    mono[i] = sum * scale
                }
                monoBuffer.frameLength = AVAudioFrameCount(n)
                inputStatus.pointee = .haveData
                return monoBuffer
            }
            if let readError { throw MixError.cannotRead(url.lastPathComponent, readError.localizedDescription) }
            if status == .error {
                throw MixError.cannotRead(url.lastPathComponent, convertError?.localizedDescription ?? "ошибка ресемплинга")
            }
            result.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0],
                                                          count: Int(outBuffer.frameLength)))
            if status == .endOfStream { break }
        }
        return result
    }
}
