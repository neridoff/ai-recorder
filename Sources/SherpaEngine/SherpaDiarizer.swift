import Foundation
import RecorderCore
import CSherpaOnnx

/// SpeakerDiarizer на sherpa-onnx (ADR-004, решения 23–26): сегментация pyannote-3.0,
/// эмбеддинги голоса, кластеризация по порогу. Расчёт на CPU, без сети.
public final class SherpaDiarizer: SpeakerDiarizer {
    public static let sherpaVersion = "v1.13.8"
    public static let segmentationFileName = "sherpa-onnx-pyannote-segmentation-3-0.onnx"
    /// Выбрана калибровкой на записях 2026-10-29 («Измерения E4» в ADR-004).
    public static let defaultEmbeddingFileName = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    public static let defaultThreshold: Float = 0.9

    public static var defaultModelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Recorder/Models", isDirectory: true)
    }

    public let modelVersion: String
    private let sd: OpaquePointer

    public init(modelsDirectory: URL = SherpaDiarizer.defaultModelsDirectory,
                embeddingFileName: String = SherpaDiarizer.defaultEmbeddingFileName,
                threshold: Float = SherpaDiarizer.defaultThreshold,
                threads: Int = min(4, ProcessInfo.processInfo.activeProcessorCount)) throws {
        let segmentation = modelsDirectory.appendingPathComponent(Self.segmentationFileName)
        let embedding = modelsDirectory.appendingPathComponent(embeddingFileName)
        for url in [segmentation, embedding] where !FileManager.default.fileExists(atPath: url.path) {
            throw DiarizationError.modelMissing(url.path)
        }
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.num_threads = Int32(threads)
        config.embedding.num_threads = Int32(threads)
        config.clustering.num_clusters = -1
        config.clustering.threshold = threshold
        // значения по умолчанию sherpa-onnx
        config.min_duration_on = 0.3
        config.min_duration_off = 0.5

        let created: OpaquePointer? = segmentation.path.withCString { seg in
            embedding.path.withCString { emb in
                "cpu".withCString { cpu in
                    config.segmentation.pyannote.model = seg
                    config.segmentation.provider = cpu
                    config.embedding.model = emb
                    config.embedding.provider = cpu
                    return SherpaOnnxCreateOfflineSpeakerDiarization(&config)
                }
            }
        }
        guard let created else {
            throw DiarizationError.engine("не удалось загрузить \(segmentation.lastPathComponent) и \(embedding.lastPathComponent)")
        }
        sd = created
        let name = embeddingFileName.replacingOccurrences(of: ".onnx", with: "")
        modelVersion = "sherpa-onnx \(Self.sherpaVersion) / pyannote-segmentation-3.0 + \(name) / threshold \(threshold)"
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(sd)
    }

    public func diarize(_ samples: [Float], progress: @escaping (Double) -> Void) throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let box = Unmanaged.passRetained(ProgressBox(progress))
        defer { box.release() }
        let result = samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
                sd, buf.baseAddress, Int32(buf.count),
                { done, total, arg in
                    if total > 0 {
                        Unmanaged<ProgressBox>.fromOpaque(arg!).takeUnretainedValue().report(Double(done) / Double(total))
                    }
                    return 0
                }, box.toOpaque())
        }
        guard let result else { throw DiarizationError.engine("разметка не вернула результат") }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0, let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }
        return (0..<count).map { i in
            let s = segments[i]
            return SpeakerTurn(startMs: Int((s.start * 1000).rounded()), endMs: Int((s.end * 1000).rounded()),
                               speaker: Int(s.speaker))
        }
    }
}

private final class ProgressBox {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
}
