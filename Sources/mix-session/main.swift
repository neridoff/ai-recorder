// mix-session: сведение дорожек сессии AI Recorder (этап E2).
// Выравнивает system.caf и mic.caf по времени первого сэмпла, ресемплирует микрофон
// к 48 кГц, пишет mixed.m4a рядом с дорожками и поле alignment в session.json.
// Печатает сдвиг старта и дрейф по anchors. Исходные дорожки не меняет.
//
//   mix-session [папка-сессии]        без аргумента: последняя сессия в ~/Documents/AI Recorder
//   mix-session --all                 все завершённые сессии и сводная таблица
//   --root <папка>                    другая корневая папка
//   --format m4a|caf                  формат сведения (по умолчанию m4a)
//   --no-write                        не менять session.json

import Foundation
import RecorderCore

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("mix-session: \(text)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var root = SessionStore.defaultRoot
var sessionDir: URL?
var format = MixFormat.m4a
var writeMetadata = true
var all = false
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--root":
        guard let value = args.first else { fail("--root требует путь") }
        args.removeFirst()
        root = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    case "--format":
        guard let value = args.first, let f = MixFormat(rawValue: value) else { fail("--format: m4a или caf") }
        args.removeFirst()
        format = f
    case "--no-write":
        writeMetadata = false
    case "--all":
        all = true
    case "-h", "--help":
        print("использование: mix-session [папка-сессии | --all] [--root <папка>] [--format m4a|caf] [--no-write]")
        exit(0)
    default:
        sessionDir = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, isDirectory: true)
    }
}

let dirs: [URL]
if let sessionDir {
    dirs = [sessionDir]
} else {
    do {
        let found = try SessionStore(root: root).sessionDirectories()
        guard let last = found.last else { fail("в \(root.path) нет сессий") }
        dirs = all ? found : [last]
    } catch {
        fail("не удалось прочитать \(root.path): \(error.localizedDescription)")
    }
}

struct Row {
    var name: String
    var record: AlignmentRecord?
    var error: String?
}

var rows: [Row] = []
for dir in dirs {
    print("Сессия: \(SessionStore(root: dir.deletingLastPathComponent()).displayTitle(of: dir)), \(dir.path)")
    do {
        let r = try SessionAlignment.run(sessionDirectory: dir, format: format, writeMetadata: writeMetadata)
        let offset = r.startOffsetMs.map { String(format: "%+.1f мс", $0) } ?? "нет (одна дорожка)"
        print("  сдвиг старта mic − system: \(offset); компенсирован: тишина перед system \(String(format: "%.1f", r.systemLeadMs)) мс, перед mic \(String(format: "%.1f", r.micLeadMs)) мс")
        print(String(format: "  сведение: %@, %.0f Гц, стерео, %.3f с", r.mixFile, r.outputSampleRate, r.mixDurationSeconds))
        if r.clippedSamples > 0 { print("  ВНИМАНИЕ: ограничено до ±1 сэмплов: \(r.clippedSamples)") }
        for line in DriftReport.describe(r.drift) { print("  \(line)") }
        print(writeMetadata ? "  alignment записан в session.json (schema ≥ 2)" : "  session.json не менялся (--no-write)")
        rows.append(Row(name: dir.lastPathComponent, record: r))
    } catch SessionAlignment.Failure.stillRecording {
        print("  пропущена: статус recording")
        rows.append(Row(name: dir.lastPathComponent, error: "recording"))
    } catch {
        print("  ОШИБКА: \(error.localizedDescription)")
        rows.append(Row(name: dir.lastPathComponent, error: error.localizedDescription))
    }
    print("")
}

if dirs.count > 1 {
    print("Сводка (сдвиг старта компенсируется при сведении; дрейф — mic − system):")
    print("  сессия                 длит., с   сдвиг, мс   дрейф, ppm   дрейф за запись, мс   на 70 мин, мс")
    for row in rows {
        guard let r = row.record else { print("  \(row.name)   \(row.error ?? "")"); continue }
        func f(_ v: Double?, _ fmt: String) -> String {
            let text = v.map { String(format: fmt, $0) } ?? "—"
            let width = String(format: fmt, 0.0).count
            return String(repeating: " ", count: max(0, width - text.count)) + text
        }
        print("  \(row.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(f(r.mixDurationSeconds, "%8.0f"))   \(f(r.startOffsetMs, "%+9.1f"))   \(f(r.drift.relativePpm, "%+10.2f"))   \(f(r.drift.driftMsAtEnd, "%+19.1f"))   \(f(r.drift.driftMsPer70Min, "%+13.1f"))")
    }
}

exit(rows.contains { $0.record == nil && $0.error != "recording" } ? 1 : 0)
