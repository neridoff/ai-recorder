import Foundation
import AVFoundation
import os

// MARK: - CAFRepair

/// Исправляет заголовок CAF PCM по фактическому размеру файла.
/// Пока AVAudioFile пишет, размер data-чанка равен −1 («до конца файла»);
/// после kill -9 он так и остаётся, а в конце может быть неполный кадр.
public enum CAFRepair {
    public struct Result: Equatable, Sendable {
        /// Сколько кадров было указано в заголовке; nil, если размер был −1.
        public var headerFramesBefore: Int64?
        public var frames: Int64
        public var truncatedBytes: Int64
        public var changed: Bool
    }

    public enum RepairError: Error, LocalizedError {
        case notCAF(String), unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .notCAF(let f): return "\(f): не CAF-файл"
            case .unsupported(let why): return "CAF не поддерживается: \(why)"
            }
        }
    }

    /// dryRun: только сообщить, что было бы исправлено, файл не трогать.
    public static func repair(url: URL, dryRun: Bool = false) throws -> Result {
        let handle = dryRun ? try FileHandle(forReadingFrom: url) : try FileHandle(forUpdating: url)
        defer { try? handle.close() }   // ошибка закрытия после успешной синхронизации ничего не меняет

        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 8), header.count == 8,
              header.prefix(4) == Data("caff".utf8) else {
            throw RepairError.notCAF(url.lastPathComponent)
        }

        var offset: Int64 = 8
        var bytesPerFrame: Int64?
        while offset + 12 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let chunkHeader = try handle.read(upToCount: 12) ?? Data()
            guard chunkHeader.count == 12 else { break }
            let type = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            let size = Int64(bitPattern: chunkHeader.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            let bodyStart = offset + 12

            if type == "desc" {
                let body = try handle.read(upToCount: 32) ?? Data()
                guard body.count == 32 else { throw RepairError.unsupported("короткий desc") }
                let formatID = String(decoding: body[8..<12], as: UTF8.self)
                let bytesPerPacket = body[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                guard formatID == "lpcm", bytesPerPacket > 0 else {
                    throw RepairError.unsupported("формат \(formatID)")
                }
                bytesPerFrame = Int64(bytesPerPacket)
            }

            if type == "data" {
                guard let bpf = bytesPerFrame else { throw RepairError.unsupported("data до desc") }
                let editCount: Int64 = 4
                let available = fileSize - bodyStart - editCount
                let declared = size == -1 ? nil : size - editCount
                // если после data есть другие чанки, заголовок верен по определению
                if let declared, declared <= available, bodyStart + size < fileSize {
                    return Result(headerFramesBefore: declared / bpf, frames: declared / bpf, truncatedBytes: 0, changed: false)
                }
                let frames = max(available, 0) / bpf
                let dataBytes = frames * bpf
                let truncated = max(available, 0) - dataBytes
                if declared == dataBytes && truncated == 0 {
                    return Result(headerFramesBefore: frames, frames: frames, truncatedBytes: 0, changed: false)
                }
                let result = Result(headerFramesBefore: declared.map { $0 / bpf }, frames: frames, truncatedBytes: truncated, changed: true)
                if dryRun { return result }
                try handle.seek(toOffset: UInt64(offset + 4))
                var newSize = UInt64(dataBytes + editCount).bigEndian
                try handle.write(contentsOf: Data(bytes: &newSize, count: 8))
                if truncated > 0 {
                    try handle.truncate(atOffset: UInt64(bodyStart + editCount + dataBytes))
                }
                try handle.synchronize()
                return result
            }

            guard size >= 0 else { throw RepairError.unsupported("чанк \(type) с размером −1 не последний") }
            offset = bodyStart + size
        }
        throw RepairError.unsupported("нет data-чанка")
    }
}

// MARK: - SessionRecovery

/// При запуске приложения находит сессии со статусом recording, чей процесс уже
/// не жив, чинит заголовки CAF по фактическому размеру и ставит статус recovered.
public struct SessionRecovery {
    public struct Report: Sendable {
        public var directory: URL
        public var status: SessionStatus
        public var messages: [String]
    }

    private let store: SessionStore
    private let isProcessAlive: (Int32) -> Bool
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "recovery")

    public init(store: SessionStore, isProcessAlive: @escaping (Int32) -> Bool = SessionRecovery.processIsAlive) {
        self.store = store
        self.isProcessAlive = isProcessAlive
    }

    /// Свой pid считается мёртвым: при запуске своя сессия ещё не идёт,
    /// совпадение — это переиспользованный pid упавшего процесса.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func recoverAll() -> [Report] {
        let dirs: [URL]
        do {
            dirs = try store.sessionDirectories()
        } catch {
            log.error("Не удалось прочитать папку сессий: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var reports: [Report] = []
        for dir in dirs {
            let meta: SessionMetadata
            do {
                meta = try store.read(from: dir)
            } catch {
                log.error("\(dir.lastPathComponent, privacy: .public): session.json не читается: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard meta.status == .recording, !isProcessAlive(meta.pid) else { continue }
            reports.append(recover(meta, in: dir))
        }
        return reports
    }

    private func recover(_ original: SessionMetadata, in dir: URL) -> Report {
        var meta = original
        var messages: [String] = []
        var latestWrite: Date?
        var readableTracks = 0

        func fix(_ track: inout TrackMetadata?) {
            guard var t = track else { return }
            let url = dir.appendingPathComponent(t.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                messages.append("\(t.file): файла нет, данные дорожки не поступали")
                return
            }
            do {
                let result = try CAFRepair.repair(url: url)
                let file = try AVAudioFile(forReading: url)
                t.sampleRate = file.fileFormat.sampleRate
                t.channels = Int(file.fileFormat.channelCount)
                t.framesWritten = file.length
                t.durationSeconds = Double(file.length) / file.fileFormat.sampleRate
                let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                if let mtime { latestWrite = max(latestWrite ?? mtime, mtime) }
                messages.append("\(t.file): \(result.frames) кадров, заголовок \(result.changed ? "исправлен" : "был верен")"
                                + (result.truncatedBytes > 0 ? ", отрезан неполный кадр (\(result.truncatedBytes) байт)" : ""))
                readableTracks += 1
                track = t
            } catch {
                messages.append("\(t.file): не удалось восстановить: \(error.localizedDescription)")
            }
        }
        fix(&meta.system)
        fix(&meta.mic)

        meta.status = readableTracks > 0 ? .recovered : .failed
        meta.stoppedAt = latestWrite ?? meta.updatedAt
        meta.updatedAt = SessionMetadata.now()
        meta.refreshDerived(clock: HostClock(numer: meta.hostTimebase.numer, denom: meta.hostTimebase.denom))
        meta.errors.append(SessionErrorRecord(
            source: "recovery",
            message: "запись прервана аварийно (pid \(original.pid)); " + messages.joined(separator: "; ")))

        do {
            try store.write(meta, to: dir)
        } catch {
            messages.append("не удалось записать session.json: \(error.localizedDescription)")
        }
        for m in messages { log.notice("\(dir.lastPathComponent, privacy: .public): \(m, privacy: .public)") }
        return Report(directory: dir, status: meta.status, messages: messages)
    }
}
