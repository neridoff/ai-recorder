import Foundation

/// Отрезок, который VAD счёл речью, с уровнем RMS в dBFS.
public struct SpeechSpan: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var rmsDb: Double

    public init(startMs: Int, endMs: Int, rmsDb: Double) {
        self.startMs = startMs
        self.endMs = endMs
        self.rmsDb = rmsDb
    }

    var durationMs: Int { endMs - startMs }
}

/// Порог по громкости поверх VAD для дорожки mic (ADR-004, решение 13).
/// Silero принимает часть фонового шума за речь, а Whisper на таком шуме выдаёт
/// повторяющийся выдуманный текст. Речь пользователя у микрофона заметно громче
/// шума, поэтому отрезок остаётся, если он тише громкой речи дорожки не больше
/// чем на relativeDb. Громкая речь = 90-й перцентиль уровня, взвешенный по длительности.
public enum SpeechGate {
    public static func filter(_ spans: [SpeechSpan], relativeDb: Double = 18, floorDb: Double = -50) -> [SpeechSpan] {
        let audible = spans.filter { $0.rmsDb >= floorDb && $0.durationMs > 0 }
        guard !audible.isEmpty else { return [] }
        let total = audible.reduce(0) { $0 + $1.durationMs }
        var accumulated = 0
        var reference = audible[0].rmsDb
        for span in audible.sorted(by: { $0.rmsDb > $1.rmsDb }) {
            accumulated += span.durationMs
            reference = span.rmsDb
            if Double(accumulated) >= Double(total) * 0.1 { break }
        }
        return audible.filter { $0.rmsDb >= reference - relativeDb }
    }
}

/// Нарезка дорожки на чанки по 5 минут (ADR-004, решение 16). Работает в сэмплах 16 кГц.
public enum ChunkPlanner {
    public static let sampleRate = 16_000
    /// Окно энергии для поиска тихой границы.
    public static let windowSamples = 1_600
    public static let chunkSamples = 300 * sampleRate
    public static let searchSamples = 5 * sampleRate
    /// Остаток короче этого присоединяется к предыдущему чанку.
    public static let minTailSamples = 30 * sampleRate

    /// excluded: паузы записи, они не расшифровываются. windowEnergy: энергия по окнам
    /// windowSamples от начала дорожки (см. windowEnergy(of:)).
    public static func plan(track: TranscriptTrack, totalSamples: Int, excluded: [Range<Int>],
                            windowEnergy: [Float]) -> [TranscriptChunk] {
        var chunks: [TranscriptChunk] = []
        for range in activeRanges(total: totalSamples, excluded: excluded) {
            var pos = range.lowerBound
            while range.upperBound - pos > chunkSamples + minTailSamples {
                let end = quietestBoundary(near: pos + chunkSamples, within: pos ..< range.upperBound,
                                           energy: windowEnergy)
                chunks.append(TranscriptChunk(track: track, index: chunks.count, startSample: pos, endSample: end))
                pos = end
            }
            if range.upperBound > pos {
                chunks.append(TranscriptChunk(track: track, index: chunks.count, startSample: pos,
                                              endSample: range.upperBound))
            }
        }
        return chunks
    }

    /// RMS² по окнам windowSamples.
    public static func windowEnergy(of samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: windowSamples).map { start in
            let end = min(start + windowSamples, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return sum / Float(end - start)
        }
    }

    static func activeRanges(total: Int, excluded: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var pos = 0
        for gap in excluded.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = min(max(gap.lowerBound, 0), total)
            if start > pos { result.append(pos ..< start) }
            pos = max(pos, min(gap.upperBound, total))
        }
        if total > pos { result.append(pos ..< total) }
        return result
    }

    /// Середина окна с минимальной энергией в ±searchSamples от target.
    private static func quietestBoundary(near target: Int, within range: Range<Int>, energy: [Float]) -> Int {
        let first = max(target - searchSamples, range.lowerBound + windowSamples) / windowSamples
        let last = min(target + searchSamples, range.upperBound - windowSamples) / windowSamples
        guard first <= last, first < energy.count else { return target }
        var best = first
        for w in first...min(last, energy.count - 1) where energy[w] < energy[best] {
            best = w
        }
        return best * windowSamples + windowSamples / 2
    }
}

/// Перевод сегментов движка во время сессии (ADR-004, решения 2 и 20).
public enum SegmentMapping {
    public static func map(_ segments: [EngineSegment], chunk: TranscriptChunk, leadMs: Double,
                           sessionId: String, modelVersion: String, language: String) -> [TranscriptSegment] {
        let samplesPerMs = ChunkPlanner.sampleRate / 1000
        let chunkLengthMs = chunk.sampleCount / samplesPerMs
        let offsetMs = Double(chunk.startSample / samplesPerMs) + leadMs
        var out: [TranscriptSegment] = []
        for s in segments where s.startMs < chunkLengthMs {
            let end = min(s.endMs, chunkLengthMs)
            out.append(TranscriptSegment(
                id: "\(chunk.track.rawValue)-\(chunk.index)-\(out.count)",
                sessionId: sessionId,
                track: chunk.track,
                speakerId: chunk.track == .mic ? TranscriptSpeaker.meId : nil,
                startMs: Int((offsetMs + Double(s.startMs)).rounded()),
                endMs: Int((offsetMs + Double(end)).rounded()),
                text: s.text,
                language: language,
                confidence: s.confidence,
                modelVersion: modelVersion))
        }
        return out
    }
}

/// Окна расшифровки по отрезкам речи (ADR-004, решение 13). Соседние отрезки
/// с паузой до maxGapMs объединяются в окно не длиннее maxWindowMs (окно Whisper 30 с).
/// Каждое окно расшифровывается отдельным вызовом, время остаётся в шкале дорожки.
public enum SpeechWindows {
    public static func plan(_ spans: [SpeechSpan], within range: Range<Int>, paddingMs: Int = 200,
                            maxGapMs: Int = 5_000, maxWindowMs: Int = 30_000) -> [Range<Int>] {
        var windows: [Range<Int>] = []
        var current: (start: Int, end: Int)?
        func close() {
            guard let c = current else { return }
            windows.append(max(c.start - paddingMs, range.lowerBound) ..< min(c.end + paddingMs, range.upperBound))
        }
        for span in spans.sorted(by: { $0.startMs < $1.startMs }) {
            let start = max(span.startMs, range.lowerBound)
            let end = min(span.endMs, range.upperBound)
            guard end > start else { continue }
            if let c = current, start - c.end <= maxGapMs, end - c.start + 2 * paddingMs <= maxWindowMs {
                current = (c.start, max(c.end, end))
            } else {
                close()
                current = (start, end)
            }
        }
        close()
        return windows
    }
}
