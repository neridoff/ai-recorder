import Foundation
import AVFoundation
import os

/// Микрофон через AVAudioEngine в родной частоте устройства (без ресемплинга).
/// Смена устройства во время записи фиксируется как ошибка, переподключения в E1 нет.
public final class MicrophoneCapture: AudioCaptureSource, @unchecked Sendable {
    public let name = "mic"
    public let deviceName: String
    public let nominalSampleRate: Double
    public let nominalChannels: Int

    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var running = false
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "capture.mic")

    public init() {
        let format = engine.inputNode.outputFormat(forBus: 0)
        nominalSampleRate = format.sampleRate
        nominalChannels = Int(format.channelCount)
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "микрофон по умолчанию"
    }

    public func start(onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void,
                      onFailure: @escaping (String) -> Void) async throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.micUnavailable("у устройства ввода нет формата (\(format))")
        }

        var invalidHostTimeReported = false
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            let hostTime: UInt64
            if time.isHostTimeValid {
                hostTime = time.hostTime
            } else {
                hostTime = mach_absolute_time()
                if !invalidHostTimeReported {
                    invalidHostTimeReported = true
                    onFailure("AVAudioTime без host time, используется время получения буфера (точность хуже)")
                }
            }
            onBuffer(buffer, hostTime)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.log.error("Конфигурация аудио изменилась во время записи")
            onFailure("конфигурация аудио изменилась (смена устройства ввода или его формата); запись микрофона прервана, переподключения в E1 нет")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.micUnavailable(error.localizedDescription)
        }
        running = true
        log.info("Захват микрофона запущен: \(self.deviceName, privacy: .public), \(format.sampleRate) Гц, \(format.channelCount) кан.")
    }

    public func stop() async {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
