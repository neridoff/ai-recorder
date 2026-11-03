import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import os

/// Системный звук через ScreenCaptureKit: 48 кГц, стерео, без звука своего процесса.
/// PTS сэмплов уже в часах хоста, они передаются дальше как тики mach_absolute_time.
public final class SystemAudioCapture: NSObject, AudioCaptureSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let name = "system"
    public private(set) var deviceName = "ScreenCaptureKit"
    public let nominalSampleRate: Double = 48_000
    public let nominalChannels = 2

    private var stream: SCStream?
    private var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var conversionFailureReported = false
    private let audioQueue = DispatchQueue(label: "airecorder.capture.system", qos: .userInitiated)
    private let screenQueue = DispatchQueue(label: "airecorder.capture.screen", qos: .utility)
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "capture.system")

    public override init() {}

    public func start(onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void,
                      onFailure: @escaping (String) -> Void) async throws {
        self.onBuffer = onBuffer
        self.onFailure = onFailure

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        deviceName = "ScreenCaptureKit, дисплей \(display.displayID)"
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(nominalSampleRate)
        config.channelCount = nominalChannels
        // Видео не нужно: минимальный кадр раз в секунду
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // Вывод экрана добавлен, как в спайке, чтобы поток не сыпал ошибками о потерянных кадрах
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        self.stream = stream
        log.info("Захват системного звука запущен")
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            onFailure?("ошибка остановки ScreenCaptureKit: \(error.localizedDescription)")
        }
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            if !conversionFailureReported {
                conversionFailureReported = true
                onFailure?("не удалось преобразовать аудиобуфер ScreenCaptureKit (дальнейшие сбои не повторяются в журнале)")
            }
            return
        }
        let hostTime = HostClock.ticks(fromHostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onBuffer?(pcm, hostTime)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("ScreenCaptureKit остановил поток: \(error.localizedDescription, privacy: .public)")
        onFailure?("ScreenCaptureKit остановил поток: \(error.localizedDescription)")
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

public enum CaptureError: LocalizedError {
    case noDisplay, micDenied, micUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "Не найден дисплей для ScreenCaptureKit (нужно разрешение «Запись экрана и системного звука»)"
        case .micDenied: return "Нет разрешения на микрофон"
        case .micUnavailable(let why): return "Микрофон недоступен: \(why)"
        }
    }
}
