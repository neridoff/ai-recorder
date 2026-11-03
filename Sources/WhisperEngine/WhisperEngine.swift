import Foundation
import RecorderCore
import whisper

/// TranscriptionEngine на whisper.cpp (ADR-004, решения 11–13, 19).
/// Контекст модели один на объект; вызовы transcribe идут последовательно.
public final class WhisperEngine: TranscriptionEngine {
    public static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"
    public static let vadModelFileName = "ggml-silero-v6.2.0.bin"

    public static var defaultModelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Recorder/Models", isDirectory: true)
    }

    public let modelVersion: String
    private let ctx: OpaquePointer
    private let vadModelPath: String
    private let threads: Int32

    public init(modelsDirectory: URL = WhisperEngine.defaultModelsDirectory,
                threads: Int = min(8, ProcessInfo.processInfo.activeProcessorCount)) throws {
        let model = modelsDirectory.appendingPathComponent(Self.modelFileName)
        let vad = modelsDirectory.appendingPathComponent(Self.vadModelFileName)
        for url in [model, vad] where !FileManager.default.fileExists(atPath: url.path) {
            throw TranscriptionError.modelMissing(url.path)
        }
        Self.silenceLogs()
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(model.path, cparams) else {
            throw TranscriptionError.engine("не удалось загрузить \(model.lastPathComponent)")
        }
        self.ctx = ctx
        self.vadModelPath = vad.path
        self.threads = Int32(threads)
        modelVersion = "whisper.cpp b5454 / large-v3-turbo-q5_0"
    }

    deinit {
        whisper_free(ctx)
    }

    public func transcribe(_ request: EngineRequest, progress: @escaping (Double) -> Void,
                           isCancelled: @escaping () -> Bool) throws -> [EngineSegment] {
        guard !request.samples.isEmpty else { return [] }
        let callbacks = Callbacks(progress: progress, isCancelled: isCancelled)
        let box = Unmanaged.passRetained(callbacks)
        defer { box.release() }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        // Чанки независимы: без контекста прошлого вызова повторный запуск даёт тот же текст
        params.no_context = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_nst = true
        params.progress_callback = { _, _, percent, user in
            Unmanaged<Callbacks>.fromOpaque(user!).takeUnretainedValue().progress(Double(percent) / 100)
        }
        params.progress_callback_user_data = box.toOpaque()
        params.abort_callback = { user in
            Unmanaged<Callbacks>.fromOpaque(user!).takeUnretainedValue().isCancelled()
        }
        params.abort_callback_user_data = box.toOpaque()

        let status: Int32 = request.language.withCString { lang in
            params.language = lang
            params.detect_language = false
            return request.samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        if isCancelled() { throw TranscriptionError.cancelled }
        guard status == 0 else { throw TranscriptionError.engine("whisper_full вернул \(status)") }
        return readSegments()
    }

    /// Отрезки речи по Silero VAD, в мс от начала samples.
    public func detectSpeech(_ samples: [Float]) throws -> [(startMs: Int, endMs: Int)] {
        var cparams = whisper_vad_default_context_params()
        cparams.n_threads = threads
        guard let vctx = whisper_vad_init_from_file_with_params(vadModelPath, cparams) else {
            throw TranscriptionError.engine("не удалось загрузить VAD")
        }
        defer { whisper_vad_free(vctx) }
        let vparams = whisper_vad_default_params()
        guard let segs = samples.withUnsafeBufferPointer({
            whisper_vad_segments_from_samples(vctx, vparams, $0.baseAddress, Int32($0.count))
        }) else { throw TranscriptionError.engine("VAD не отработал") }
        defer { whisper_vad_free_segments(segs) }
        // t0/t1 в сотых долях секунды, как у сегментов whisper
        return (0..<whisper_vad_segments_n_segments(segs)).map {
            (Int(whisper_vad_segments_get_segment_t0(segs, $0) * 10), Int(whisper_vad_segments_get_segment_t1(segs, $0) * 10))
        }
    }

    private func readSegments() -> [EngineSegment] {
        let eot = whisper_token_eot(ctx)
        var out: [EngineSegment] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            let text = String(cString: whisper_full_get_segment_text(ctx, i))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var logSum = 0.0
            var count = 0
            for t in 0..<whisper_full_n_tokens(ctx, i) where whisper_full_get_token_id(ctx, i, t) < eot {
                logSum += log(max(Double(whisper_full_get_token_p(ctx, i, t)), 1e-10))
                count += 1
            }
            // t0/t1 в сотых долях секунды
            out.append(EngineSegment(startMs: Int(whisper_full_get_segment_t0(ctx, i)) * 10,
                                     endMs: Int(whisper_full_get_segment_t1(ctx, i)) * 10,
                                     text: text,
                                     confidence: count > 0 ? exp(logSum / Double(count)) : 0))
        }
        return out
    }

    /// whisper.cpp и ggml пишут подробный журнал в stderr; для CLI и приложения он лишний.
    private static func silenceLogs() {
        whisper_log_set({ _, _, _ in }, nil)
    }

    private final class Callbacks {
        let progress: (Double) -> Void
        let isCancelled: () -> Bool
        init(progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) {
            self.progress = progress
            self.isCancelled = isCancelled
        }
    }
}
