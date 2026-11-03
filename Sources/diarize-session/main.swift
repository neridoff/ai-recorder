// diarize-session: разметка говорящих по готовой расшифровке (E4, ADR-004 решения 23–30).
// Пишет speakerId, overlapWith и speakers[] в transcript.json и блок diarization в session.json.
// Без сети: модели читаются из ~/Library/Application Support/AI Recorder/Models (scripts/fetch-models.sh).
// Если в папке сессии есть Labels.txt (метки Audacity: начало, конец, имя), печатается сверка FR-05.
//
//   diarize-session                       последняя сессия
//   diarize-session <папка>               указанная сессия
//   diarize-session --all                 все расшифрованные сессии без разметки
//   --threshold 0.9                       порог кластеризации (больше — меньше собеседников)
//   --embedding <файл.onnx>               другая модель голоса из папки моделей (для калибровки)
//   --multiple-voices on|off              записать флаг «несколько голосов в комнате» в session.json
import Foundation
import RecorderCore
import SherpaEngine

func usage() -> Never {
    print("использование: diarize-session [<папка сессии> | --all] [--threshold X] [--embedding <файл.onnx>] [--multiple-voices on|off]")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var all = false
var threshold = SherpaDiarizer.defaultThreshold
var embedding = SherpaDiarizer.defaultEmbeddingFileName
var multipleVoices: Bool?
var path: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--all": all = true
    case "--threshold":
        guard let v = args.first.flatMap(Float.init) else { usage() }
        args.removeFirst()
        threshold = v
    case "--embedding":
        guard !args.isEmpty else { usage() }
        embedding = args.removeFirst()
    case "--multiple-voices":
        guard let v = args.first, v == "on" || v == "off" else { usage() }
        args.removeFirst()
        multipleVoices = v == "on"
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
            return meta.transcription?.status == .done && meta.diarization?.status != .done
        }
    }
    guard let last = dirs.last else {
        print("сессий нет в \(store.root.path)")
        exit(1)
    }
    return [last]
}

func run() -> Int32 {
    let dirs: [URL]
    do { dirs = try targets() } catch {
        print("ошибка: \(error.localizedDescription)")
        return 1
    }
    if dirs.isEmpty {
        print("нечего размечать")
        return 0
    }
    let diarizer: SherpaDiarizer
    do { diarizer = try SherpaDiarizer(embeddingFileName: embedding, threshold: threshold) } catch {
        print("ошибка: \(error.localizedDescription)")
        return 1
    }
    print("модель: \(diarizer.modelVersion)")

    var failures = 0
    for dir in dirs {
        print("\n\(store.displayTitle(of: dir)) (\(dir.lastPathComponent))")
        do {
            if let multipleVoices {
                var meta = try store.read(from: dir)
                meta.multipleVoices = multipleVoices
                try store.write(meta, to: dir)
            }
            var lastPercent = -1
            let transcript = try DiarizationJob(directory: dir, diarizer: diarizer).run(progress: { p in
                let percent = Int(p * 100)
                guard percent / 25 != lastPercent / 25 else { return }
                lastPercent = percent
                print("  разметка \(percent)%")
            })
            DiarizationSummary.lines(transcript: transcript, meta: try? store.read(from: dir), directory: dir)
                .forEach { print($0) }
        } catch {
            failures += 1
            print("  ошибка: \(error.localizedDescription)")
        }
    }
    return failures == 0 ? 0 : 1
}

exit(run())
