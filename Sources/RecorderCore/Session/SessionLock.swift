import Foundation

/// Блокировка обработки сессии файлом с pid: расшифровка и разметка одной сессии
/// не идут одновременно в двух процессах (ADR-004 решение 17).
struct SessionLock {
    static let fileName = ".transcription.lock"

    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    func acquire() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let holder = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(holder, 0) == 0 || errno == EPERM {
            throw TranscriptionError.alreadyRunning(holder)
        }
        try "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
