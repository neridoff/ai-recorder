// transcribe-session: расшифровка сессии (E3, ADR-004) и следом разметка говорящих (E4).
// Пишет transcript.json и читабельный transcript.md (FR-15) в папку сессии и блоки
// transcription и diarization в session.json.
// Без сети: модели читаются
// из ~/Library/Application Support/AI Recorder/Models (scripts/fetch-models.sh).
//
//   transcribe-session                 последняя сессия
//   transcribe-session <папка>         указанная сессия
//   transcribe-session --all           все завершённые сессии без готовой расшифровки
//   --restart                          начать заново, не продолжать с готовых чанков
//   --language auto                    определять язык (по умолчанию ru)
//   --system-whole                     system целиком, без VAD (для сравнения, ADR-004 решение 22)
//   --no-diarize                       только расшифровка, без этапа «Разметка» (повтор: diarize-session)
import Foundation
import RecorderCore
import WhisperEngine
import SherpaEngine

func usage() -> Never {
    print("использование: transcribe-session [<папка сессии> | --all] [--restart] [--language ru|auto] [--system-whole] [--no-diarize]")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var restart = false
var systemVAD = true
var all = false
var language = "ru"
var diarize = true
var path: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--restart": restart = true
    case "--system-whole": systemVAD = false
    case "--all": all = true
    case "--no-diarize": diarize = false
    case "--language":
        guard !args.isEmpty else { usage() }
        language = args.removeFirst()
    case "-h", "--help": usage()
    default:
        guard path == nil, !a.hasPrefix("-") else { usage() }
        path = a
    }
}

let store = SessionStore()

func targets() throws -> [URL] {
    if let path { return [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)] }
    let dirs = try store.sessionDirectories()
    if all {
        return dirs.filter { dir in
            guard let meta = try? store.read(from: dir) else { return false }
            return meta.status != .recording && meta.transcription?.status != .done
        }
    }
    guard let last = dirs.last else {
        print("сессий нет в \(store.root.path)")
        exit(1)
    }
    return [last]
}

func describe(_ meta: SessionMetadata) -> [String] {
    guard let t = meta.transcription else { return [] }
    var lines = [String(format: "  звук: %.1f мин (system и mic по времени дорожки, без пауз)", t.audioSeconds / 60)]
    if let speech = t.micSpeechSeconds {
        lines.append(String(format: "  речь mic после VAD: %.1f мин", speech / 60))
    }
    lines.append(String(format: "  обработка: %.1f с, %.1f× быстрее реального времени",
                        t.processingSeconds, t.realtimeFactor ?? 0))
    if let system = meta.system, system.durationSeconds > 0 {
        // NFR-02: час записи (60 мин system плюс речь mic) не дольше 5 мин обработки.
        // Время обработки этой записи пересчитывается на час линейно.
        let estimate = t.processingSeconds * 3600 / system.durationSeconds
        lines.append(String(format: "  оценка NFR-02: час записи ≈ %.1f мин обработки (норма ≤ 5 мин)", estimate / 60))
    }
    return lines
}

func run() -> Int32 {
    let dirs: [URL]
    do { dirs = try targets() } catch {
        print("ошибка: \(error.localizedDescription)")
        return 1
    }
    if dirs.isEmpty {
        print("нечего расшифровывать")
        return 0
    }
    let engine: WhisperEngine
    let loadStart = Date()
    do { engine = try WhisperEngine() } catch {
        print("ошибка: \(error.localizedDescription)")
        return 1
    }
    print(String(format: "модель: %@, загружена за %.1f с", engine.modelVersion, Date().timeIntervalSince(loadStart)))
    var diarizer: SherpaDiarizer?
    if diarize {
        do { diarizer = try SherpaDiarizer() } catch {
            print("ошибка: \(error.localizedDescription)")
            return 1
        }
        print("разметка: \(diarizer!.modelVersion)")
    }

    var failures = 0
    for dir in dirs {
        print("\n\(store.displayTitle(of: dir)) (\(dir.lastPathComponent))")
        var lastPercent = -1
        let job = TranscriptionJob(directory: dir, engine: engine, language: language, systemVAD: systemVAD)
        do {
            let transcript = try job.run(restart: restart, progress: { p in
                let percent = Int(p.fraction * 100)
                guard percent / 5 != lastPercent / 5 else { return }
                lastPercent = percent
                print("  расшифровка \(percent)% (чанков \(p.chunksDone)/\(p.chunksTotal)\(p.track.map { ", \($0.rawValue)" } ?? ""))")
            })
            let counts = Dictionary(grouping: transcript.segments, by: \.track).mapValues(\.count)
            print("  готово: \(Transcript.fileName), реплик \(transcript.segments.count) (system \(counts[.system] ?? 0), mic \(counts[.mic] ?? 0))")
            if let meta = try? store.read(from: dir) {
                describe(meta).forEach { print($0) }
            }
            // Этап «Разметка» идёт после расшифровки (ADR-004 решение 8)
            var result = transcript
            if transcript.segments.isEmpty {
                // ADR-006 решение 1: речи нет — разметке нечего делить, transcript.md не пишется
                print("  расшифровка пустая: речи не найдено, разметка пропущена, аудио не сжимается")
                failures += 1
                continue
            }
            if let diarizer {
                print("  разметка говорящих…")
                result = try DiarizationJob(directory: dir, diarizer: diarizer).run()
                DiarizationSummary.lines(transcript: result, meta: try? store.read(from: dir), directory: dir)
                    .forEach { print($0) }
            }
            let md = try TranscriptMarkdown.write(result, meta: try? store.read(from: dir), to: dir)
            print("  читабельный текст: \(md.lastPathComponent)")
        } catch {
            failures += 1
            print("  ошибка: \(error.localizedDescription)")
        }
    }
    return failures == 0 ? 0 : 1
}

// Движок освобождается внутри run(): иначе ggml-metal падает на проверке при exit
exit(run())
