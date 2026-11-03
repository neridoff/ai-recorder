import Foundation
import os

/// Поле alignment в session.json (схема 2): как дорожки сведены и какой у них дрейф.
public struct AlignmentRecord: Codable, Equatable, Sendable {
    public var analyzedAt: Date
    public var mixFile: String
    public var outputSampleRate: Double
    /// Кадр 0 сведения: первый сэмпл дорожки, стартовавшей раньше.
    public var originHostTime: HostInstant
    /// mic − system, мс.
    public var startOffsetMs: Double?
    /// Тишина перед дорожкой в сведении, мс.
    public var systemLeadMs: Double
    public var micLeadMs: Double
    public var mixDurationSeconds: Double
    /// Сэмплы, ограниченные до ±1 при сложении.
    public var clippedSamples: Int
    public var drift: DriftReport
}

/// Сведение сессии и замер дрейфа: mixed.<формат> рядом с дорожками, alignment в session.json.
public enum SessionAlignment {
    public enum Failure: LocalizedError, Equatable {
        case stillRecording

        public var errorDescription: String? {
            "сессия в статусе recording: запись идёт или ещё не восстановлена после сбоя"
        }
    }

    static let log = Logger(subsystem: RecorderLog.subsystem, category: "alignment")

    public static func mixFileName(_ format: MixFormat) -> String { "mixed.\(format.fileExtension)" }

    @discardableResult
    public static func run(sessionDirectory dir: URL, format: MixFormat = .m4a,
                           writeMetadata: Bool = true, now: Date = SessionMetadata.now()) throws -> AlignmentRecord {
        let store = SessionStore(root: dir.deletingLastPathComponent())
        var meta = try store.read(from: dir)
        guard meta.status != .recording else { throw Failure.stillRecording }

        let drift = DriftReport.measure(meta)
        let output = dir.appendingPathComponent(mixFileName(format))
        let result: MixResult
        do {
            result = try SessionMixer.mix(sessionDirectory: dir, metadata: meta, output: output, format: format)
        } catch {
            log.error("\(dir.lastPathComponent, privacy: .public): сведение не удалось: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let plan = result.plan
        let clock = HostClock(numer: meta.hostTimebase.numer, denom: meta.hostTimebase.denom)
        let record = AlignmentRecord(
            analyzedAt: now,
            mixFile: output.lastPathComponent,
            outputSampleRate: plan.outputRate,
            originHostTime: HostInstant(ticks: plan.originTicks, clock: clock),
            startOffsetMs: plan.startOffsetMs,
            systemLeadMs: Double(plan.systemLeadFrames) / plan.outputRate * 1000,
            micLeadMs: Double(plan.micLeadFrames) / plan.outputRate * 1000,
            mixDurationSeconds: Double(result.frames) / plan.outputRate,
            clippedSamples: result.clippedSamples,
            drift: drift)
        logRecord(record, session: dir.lastPathComponent)

        if writeMetadata {
            meta.alignment = record
            meta.schemaVersion = max(meta.schemaVersion, 2)   // alignment появился в схеме 2
            try store.write(meta, to: dir)
        }
        return record
    }

    private static func logRecord(_ r: AlignmentRecord, session: String) {
        let offset = r.startOffsetMs.map { String(format: "%+.1f", $0) } ?? "—"
        log.notice("\(session, privacy: .public): сведено в \(r.mixFile, privacy: .public), \(String(format: "%.1f", r.mixDurationSeconds), privacy: .public) с; сдвиг старта mic − system \(offset, privacy: .public) мс; ограничено сэмплов: \(r.clippedSamples)")
        for line in DriftReport.describe(r.drift) {
            log.notice("\(session, privacy: .public): \(line, privacy: .public)")
        }
    }
}

extension DriftReport {
    /// Строки отчёта о дрейфе для CLI и журнала.
    public static func describe(_ r: DriftReport) -> [String] {
        func track(_ label: String, _ d: TrackDrift?) -> String {
            guard let d else { return "\(label): дрейф не измерен (нужно ≥ 2 anchors на ≥ \(Int(TrackDrift.minimumSpanSeconds)) с)" }
            return String(format: "%@: %+.2f ppm (%.3f Гц при номинале %.0f), anchors %d на %.0f с, дрожание меток до %.2f мс",
                          label, d.ppm, d.measuredRate, d.nominalRate, d.anchorCount, d.spanSeconds, d.maxResidualMs)
        }
        var lines = [track("дрейф system", r.system), track("дрейф mic", r.mic)]
        if let ppm = r.relativePpm, let end = r.driftMsAtEnd, let per70 = r.driftMsPer70Min {
            lines.append(String(format: "дрейф mic − system: %+.2f ppm, %+.1f мс за %.0f с записи, %+.1f мс на 70 мин",
                                ppm, end, r.sessionSeconds, per70))
        }
        return lines
    }
}
