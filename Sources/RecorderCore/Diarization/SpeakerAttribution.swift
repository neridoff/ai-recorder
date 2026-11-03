import Foundation

/// Ход говорящего от diarization: время в мс от alignment.originHostTime, номер кластера.
public struct SpeakerTurn: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var speaker: Int

    public init(startMs: Int, endMs: Int, speaker: Int) {
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
    }
}

/// Привязка реплик к говорящим и перекрытия (ADR-004, решения 3, 5, 6). Без ввода-вывода.
public enum SpeakerAttribution {
    /// Реплика без пересечения с ходами берёт ближайший ход не дальше этого.
    public static let maxGapMs = 2000
    /// Перебивание: реплики разных говорящих пересекаются хотя бы на столько.
    /// Меньшие пересечения дают неточные границы сегментов Whisper.
    public static let minOverlapMs = 250

    public static func speakerId(_ number: Int) -> String { "speaker-\(number)" }
    public static func speakerLabel(_ number: Int) -> String { "Собеседник \(number)" }

    /// Заполняет speakerId и overlapWith, возвращает список говорящих.
    /// system: кластеры → «Собеседник 1…N» по первой реплике. mic: без micTurns целиком «Я»;
    /// с micTurns (флаг «несколько голосов в комнате») кластер с наибольшей речью = «Я»,
    /// остальные продолжают нумерацию собеседников. Кластеры дорожек не сопоставляются.
    public static func apply(segments: [TranscriptSegment], sessionId: String,
                             systemTurns: [SpeakerTurn], micTurns: [SpeakerTurn]?)
        -> (segments: [TranscriptSegment], speakers: [TranscriptSpeaker]) {
        var result = segments
        let systemClusters = result.map { $0.track == .system ? cluster(for: $0, in: systemTurns) : nil }
        let micClusters = result.map { s -> Int? in
            guard s.track == .mic, let micTurns else { return nil }
            return cluster(for: s, in: micTurns)
        }

        // «Я» на mic: кластер с наибольшей суммарной длительностью реплик
        var micSpeech: [Int: Int] = [:]
        for (i, c) in micClusters.enumerated() {
            if let c { micSpeech[c, default: 0] += result[i].endMs - result[i].startMs }
        }
        let meCluster = micSpeech.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key

        var numbers: [String: Int] = [:]   // "system:3" → номер собеседника
        func number(_ key: String) -> Int {
            if let n = numbers[key] { return n }
            numbers[key] = numbers.count + 1
            return numbers.count
        }
        // Сначала все собеседники system, потом лишние голоса mic
        for i in result.indices where result[i].track == .system {
            result[i].speakerId = systemClusters[i].map { speakerId(number("system:\($0)")) }
        }
        for i in result.indices where result[i].track == .mic {
            if let c = micClusters[i], c != meCluster {
                result[i].speakerId = speakerId(number("mic:\(c)"))
            } else {
                result[i].speakerId = TranscriptSpeaker.meId
            }
        }

        let overlap = overlaps(result)
        for i in result.indices { result[i].overlapWith = overlap[result[i].id] ?? [] }

        var speakers: [TranscriptSpeaker] = []
        if result.contains(where: { $0.speakerId == TranscriptSpeaker.meId }) {
            speakers.append(TranscriptSpeaker(id: TranscriptSpeaker.meId, sessionId: sessionId, label: "Я", displayName: nil))
        }
        for n in numbers.values.sorted() {
            speakers.append(TranscriptSpeaker(id: speakerId(n), sessionId: sessionId, label: speakerLabel(n), displayName: nil))
        }
        return (result, speakers)
    }

    /// Кластер с наибольшим пересечением; без пересечения ближайший в пределах maxGapMs.
    static func cluster(for s: TranscriptSegment, in turns: [SpeakerTurn]) -> Int? {
        var best: (overlap: Int, speaker: Int)?
        var nearest: (gap: Int, speaker: Int)?
        for t in turns {
            let overlap = min(s.endMs, t.endMs) - max(s.startMs, t.startMs)
            if overlap > 0 {
                if best == nil || overlap > best!.overlap { best = (overlap, t.speaker) }
            } else if -overlap <= maxGapMs, nearest == nil || -overlap < nearest!.gap {
                nearest = (-overlap, t.speaker)
            }
        }
        return best?.speaker ?? nearest?.speaker
    }

    /// id реплики → пересекающиеся реплики других говорящих (решение 5), в порядке списка.
    /// Реплики одного говорящего не считаются перебиванием; без speakerId сравнивается дорожка.
    public static func overlaps(_ segments: [TranscriptSegment], minOverlapMs: Int = minOverlapMs) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let sorted = segments.enumerated().sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }
        for (i, (_, a)) in sorted.enumerated() {
            for (_, b) in sorted[(i + 1)...] {
                if b.startMs >= a.endMs { break }
                let sameSpeaker = a.speakerId != nil || b.speakerId != nil
                    ? a.speakerId == b.speakerId && a.track == b.track
                    : a.track == b.track
                guard !sameSpeaker, min(a.endMs, b.endMs) - b.startMs >= minOverlapMs else { continue }
                result[a.id, default: []].append(b.id)
                result[b.id, default: []].append(a.id)
            }
        }
        // в порядке исходного списка
        let order = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
        return result.mapValues { $0.sorted { order[$0]! < order[$1]! } }
    }
}
