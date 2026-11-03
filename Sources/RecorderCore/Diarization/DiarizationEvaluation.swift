import Foundation

/// Эталонная метка начала реплики (Labels.txt из Audacity): время от начала mixed.m4a и имя.
public struct ReferenceLabel: Equatable, Sendable {
    public var ms: Int
    public var name: String

    public init(ms: Int, name: String) {
        self.ms = ms
        self.name = name
    }

    /// «я» или «Я»: пользователь, его реплики должны попасть на «Я».
    public var isMe: Bool { name.lowercased() == "я" }

    /// Формат Audacity: начало, конец, имя через табуляцию. Пустые и неполные строки пропускаются.
    public static func parseAudacity(_ text: String) -> [ReferenceLabel] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, let start = Double(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            let name = parts[2].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return ReferenceLabel(ms: Int((start * 1000).rounded()), name: name)
        }
    }
}

/// Отчёт FR-05 по одной записи.
public struct DiarizationReport: Equatable, Sendable {
    /// Все метки, включая «я».
    public var total: Int
    /// Верно при сопоставлении «один кластер — одно имя» (решение 31). Справка, не критерий
    /// (ADR-004 решение 33).
    public var correct: Int
    /// Верно, если каждому кластеру дать самое частое у него имя, вместе с «я».
    public var correctManyToOne: Int
    public var meTotal: Int
    public var meCorrect: Int
    /// Метки собеседников (без «я»).
    public var othersTotal: Int
    /// Метки собеседников, совпавшие с самым частым именем своего кластера.
    public var othersCorrectManyToOne: Int
    /// Метки, рядом с которыми нет ни одной реплики.
    public var unmatched: Int
    /// speakerId → имя при сопоставлении один к одному.
    public var mapping: [String: String]
    /// Сколько разных говорящих (кроме «Я») досталось меткам и сколько имён в эталоне.
    public var clusters: Int
    public var names: Int
    /// Больше всего кластеров, у которых самое частое имя одно и то же (дробление одного человека).
    public var maxClustersOfOneSpeaker: Int

    public var accuracy: Double { total > 0 ? Double(correct) / Double(total) : 0 }
    public var accuracyManyToOne: Double { total > 0 ? Double(correctManyToOne) / Double(total) : 0 }
    /// Чистота кластеров (критерий FR-05, вариант B): все метки, вместе с «я»; каждому кластеру
    /// его самое частое имя (решение пользователя 02.11.2026, ADR-004 решение 41).
    public var purity: Double { accuracyManyToOne }
    public var clustersPerSpeaker: Double { names > 0 ? Double(clusters) / Double(names) : 0 }

    /// Критерий FR-05 (ADR-004 решение 33): чистота не ниже порога и кластеров не больше
    /// лимита, умноженного на число собеседников в эталоне.
    public var meetsCriterion: Bool {
        purity >= DiarizationEvaluation.purityThreshold
            && clusters <= DiarizationEvaluation.maxClustersPerSpeaker * names
    }
}

/// Сравнение разметки с эталоном (FR-05): метка → реплика, начинающаяся ближе всего к метке,
/// кластеры сопоставляются с именами внутри записи.
public enum DiarizationEvaluation {
    /// Реплика ищется с началом в пределах этого от метки; иначе реплика, покрывающая метку.
    public static let toleranceMs = 2000
    /// Порог чистоты кластеров FR-05, вариант B (ADR-004 решение 33, 02.11.2026).
    public static let purityThreshold = 0.85
    /// Лимит кластеров на собеседника FR-05 (ADR-004 решение 33): дробление одного человека
    /// допустимо, но не больше чем на 5 кластеров в среднем по записи. Слияние не делается.
    public static let maxClustersPerSpeaker = 5

    public static func evaluate(labels: [ReferenceLabel], segments: [TranscriptSegment]) -> DiarizationReport {
        var pairs: [(label: ReferenceLabel, speaker: String?)] = []
        var unmatched = 0
        for label in labels {
            let preferred: TranscriptTrack = label.isMe ? .mic : .system
            guard let replica = nearest(label.ms, in: segments.filter { $0.track == preferred })
                    ?? nearest(label.ms, in: segments) else {
                unmatched += 1
                pairs.append((label, nil))
                continue
            }
            pairs.append((label, replica.speakerId))
        }

        let me = pairs.filter { $0.label.isMe }
        let meCorrect = me.filter { $0.speaker == TranscriptSpeaker.meId }.count
        let others = pairs.filter { !$0.label.isMe }

        var counts: [String: [String: Int]] = [:]
        for p in others {
            guard let s = p.speaker, s != TranscriptSpeaker.meId else { continue }
            counts[s, default: [:]][p.label.name, default: 0] += 1
        }
        let manyToOne = counts.values.reduce(0) { $0 + ($1.values.max() ?? 0) }
        // Самое частое имя кластера; при равенстве первое по алфавиту, чтобы отчёт не плавал
        let dominant = counts.values.compactMap { names in
            names.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
        let maxSplit = Dictionary(grouping: dominant, by: { $0 }).values.map(\.count).max() ?? 0

        // Один к одному: жадно по убыванию совпадений, матрица маленькая
        let cells = counts.flatMap { s, names in names.map { (count: $0.value, speaker: s, name: $0.key) } }
            .sorted { ($0.count, $1.speaker, $1.name) > ($1.count, $0.speaker, $0.name) }
        var mapping: [String: String] = [:]
        var usedNames = Set<String>()
        var oneToOne = 0
        for c in cells where mapping[c.speaker] == nil && !usedNames.contains(c.name) {
            mapping[c.speaker] = c.name
            usedNames.insert(c.name)
            oneToOne += c.count
        }

        return DiarizationReport(
            total: pairs.count, correct: oneToOne + meCorrect, correctManyToOne: manyToOne + meCorrect,
            meTotal: me.count, meCorrect: meCorrect, othersTotal: others.count, othersCorrectManyToOne: manyToOne,
            unmatched: unmatched, mapping: mapping,
            clusters: counts.count, names: Set(others.map(\.label.name)).count, maxClustersOfOneSpeaker: maxSplit)
    }

    private static func nearest(_ ms: Int, in segments: [TranscriptSegment]) -> TranscriptSegment? {
        let near = segments.filter { abs($0.startMs - ms) <= toleranceMs }
            .min { (abs($0.startMs - ms), $0.startMs) < (abs($1.startMs - ms), $1.startMs) }
        return near ?? segments.first { $0.startMs <= ms && ms < $0.endMs }
    }
}
