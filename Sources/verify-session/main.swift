// verify-session: проверка сессии AI Recorder.
// Открывает дорожки через AVAudioFile, сверяет их с session.json, печатает
// сдвиг старта, разрывы, задержку старта и статус. Файлы не меняет.
//
//   verify-session [папка-сессии]        без аргумента: последняя сессия в ~/Documents/AI Recorder
//   verify-session --root <папка>        последняя сессия в другой корневой папке

import Foundation
import AVFoundation
import RecorderCore

var problems: [String] = []
var warnings: [String] = []

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("verify-session: \(text)\n".utf8))
    exit(2)
}

// MARK: Аргументы

var args = Array(CommandLine.arguments.dropFirst())
var root = SessionStore.defaultRoot
var sessionDir: URL?
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--root":
        guard let value = args.first else { fail("--root требует путь") }
        args.removeFirst()
        root = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    case "-h", "--help":
        print("использование: verify-session [папка-сессии] [--root <папка>]")
        exit(0)
    default:
        sessionDir = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, isDirectory: true)
    }
}

let store = SessionStore(root: sessionDir?.deletingLastPathComponent() ?? root)
if sessionDir == nil {
    do {
        guard let last = try store.sessionDirectories().last else { fail("в \(root.path) нет сессий") }
        sessionDir = last
    } catch {
        fail("не удалось прочитать \(root.path): \(error.localizedDescription)")
    }
}
let dir = sessionDir!

let meta: SessionMetadata
do {
    meta = try store.read(from: dir)
} catch {
    fail("\(dir.path)/session.json не читается: \(error.localizedDescription)")
}

// MARK: Сессия

let iso = ISO8601DateFormatter()
print("Запись:     \(SessionStore.displayTitle(startedAt: meta.startedAt))")
print("Сессия:     \(dir.path)")
print("Статус:     \(meta.status.rawValue)")
print("Старт:      \(iso.string(from: meta.startedAt))")
print("Стоп:       \(meta.stoppedAt.map(iso.string(from:)) ?? "—")")
print("Приложение: \(meta.appVersion), macOS: \(meta.osVersion), schema \(meta.schemaVersion)")
print("Timebase:   \(meta.hostTimebase.numer)/\(meta.hostTimebase.denom)")
if let c = meta.compression {
    print("Сжатие:     \(c.status.rawValue)" + (c.error.map { ", \($0)" } ?? "")
          + c.tracks.map { " \($0.originalFile) → \($0.file) \($0.codec) \($0.bitRate / 1000) кбит/с" }.joined(separator: ","))
}
if meta.audioDeleted == true {
    // E5: дорожек больше нет, проверять нечего
    print("Аудио удалено по сроку хранения (\(meta.audioDeletedReason?.rawValue ?? "retention")): \(meta.audioDeletedAt.map(iso.string(from:)) ?? "—"), текст и session.json сохранены")
    exit(0)
}

switch meta.status {
case .completed, .recovered: break
case .recording: warnings.append("статус recording: запись идёт или приложение ещё не запускалось после сбоя")
case .failed: problems.append("статус failed")
}

// MARK: Дорожки

struct TrackCheck {
    var frames: Int64
    var duration: Double
}

func check(_ track: TrackMetadata?, label: String) -> TrackCheck? {
    print("")
    guard let track else {
        problems.append("\(label): нет в session.json")
        print("[\(label)] нет в session.json")
        return nil
    }
    let url = dir.appendingPathComponent(track.file)
    print("[\(label)] \(track.file), устройство: \(track.deviceName)")

    // после сжатия (E5) дорожка в m4a: заголовок CAF проверять не у чего
    if url.pathExtension == "caf" {
        do {
            let header = try CAFRepair.repair(url: url, dryRun: true)
            if header.changed {
                let before = header.headerFramesBefore.map { "\($0) кадров" } ?? "−1 (не финализирован)"
                warnings.append("\(label): заголовок CAF указывает \(before), фактически \(header.frames)")
            }
        } catch {
            warnings.append("\(label): заголовок CAF не разобран: \(error.localizedDescription)")
        }
    }

    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        problems.append("\(label): AVAudioFile не открывает \(track.file): \(error.localizedDescription)")
        print("  НЕ ОТКРЫВАЕТСЯ: \(error.localizedDescription)")
        return nil
    }
    let rate = file.fileFormat.sampleRate
    let duration = Double(file.length) / rate
    print(String(format: "  формат:        %.0f Гц, %d кан., %@", rate, file.fileFormat.channelCount,
                 file.fileFormat.commonFormat == .pcmFormatFloat32 ? "Float32 PCM" : "\(file.fileFormat.commonFormat.rawValue)"))
    print(String(format: "  кадров в файле: %lld (%.3f с)", file.length, duration))
    print(String(format: "  кадров в json:  %lld (%.3f с)", track.framesWritten, track.durationSeconds))
    if file.length != track.framesWritten {
        let diff = Double(file.length - track.framesWritten) / rate
        let text = String(format: "%@: файл и session.json расходятся на %.3f с", label, diff)
        // во время записи json отстаёт до 5 с, после stop/recovery должен совпадать
        if meta.status == .recording { warnings.append(text) } else { problems.append(text) }
    }
    if rate != track.sampleRate {
        problems.append("\(label): частота файла \(rate) ≠ \(track.sampleRate) в session.json")
    }

    if let first = track.firstSampleHostTime {
        print(String(format: "  первый сэмпл:  host %.6f с (%llu тиков)", first.seconds, first.ticks))
    } else {
        problems.append("\(label): нет firstSampleHostTime")
    }
    if let latency = track.startLatencyMs {
        let ok = latency <= 2000
        print(String(format: "  старт:         %.0f мс от нажатия (FR-01 ≤ 2000 мс: %@)", latency, ok ? "да" : "НЕТ"))
        if !ok { problems.append(String(format: "%@: старт %.0f мс > 2000 мс (FR-01)", label, latency)) }
    }
    let filled = track.gaps.reduce(0.0) { $0 + max($1.durationMs, 0) }
    print(String(format: "  разрывы:       %d (заполнено тишиной %.0f мс)", track.gaps.count, filled))
    for gap in track.gaps.prefix(10) {
        print(String(format: "                 кадр %lld: %+.1f мс", gap.atFrame, gap.durationMs))
    }
    if track.gaps.count > 10 { print("                 … ещё \(track.gaps.count - 10)") }
    print("  anchors:       \(track.anchors.count)")
    return TrackCheck(frames: file.length, duration: duration)
}

let system = check(meta.system, label: "system")
let mic = check(meta.mic, label: "mic")

// MARK: Сводка

print("")
if let offset = meta.startOffsetMs {
    let note = abs(offset) <= 100 ? "в пределах 100 мс" : "больше 100 мс, выравнивается в E2 по этому значению"
    print(String(format: "Сдвиг старта mic − system: %+.1f мс (%@)", offset, note))
} else {
    problems.append("нет startOffsetMs")
    print("Сдвиг старта mic − system: нет данных")
}
if let system, let mic {
    let diff = mic.duration - system.duration
    print(String(format: "Длительность: system %.3f с, mic %.3f с, разница %+.3f с", system.duration, mic.duration, diff))
    // Конец записи у обеих дорожек общий, поэтому разница длительностей ≈ −сдвиг старта
    if let offset = meta.startOffsetMs {
        let residual = diff * 1000 + offset
        print(String(format: "  разница длительностей + сдвиг старта = %+.0f мс (около нуля, если дорожки идут без потерь)", residual))
        if abs(residual) > 500 { warnings.append(String(format: "длительности дорожек расходятся на %.0f мс сверх сдвига старта", residual)) }
    }
    if let stopped = meta.stoppedAt {
        let wall = stopped.timeIntervalSince(meta.startedAt)
        print(String(format: "  по часам: %.0f с от startedAt до stoppedAt (точность 1 с)", wall))
    }
}

// Дрейф по anchors (E2): только печать, session.json не меняется
print("")
for line in DriftReport.describe(DriftReport.measure(meta)) { print(line) }
if let a = meta.alignment {
    print(String(format: "Сведение: %@ (%.1f с), выполнено %@", a.mixFile, a.mixDurationSeconds, iso.string(from: a.analyzedAt)))
}

if !meta.errors.isEmpty {
    print("")
    print("Ошибки в session.json (\(meta.errors.count)):")
    for e in meta.errors { print("  \(iso.string(from: e.at)) [\(e.source)] \(e.message)") }
}

print("")
for w in warnings { print("ВНИМАНИЕ: \(w)") }
for p in problems { print("ПРОБЛЕМА: \(p)") }
let ok = problems.isEmpty
print(ok ? "ИТОГ: OK" : "ИТОГ: ЕСТЬ ПРОБЛЕМЫ")
exit(ok ? 0 : 1)
