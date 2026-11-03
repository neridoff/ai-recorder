import Foundation

/// Читабельная расшифровка transcript.md (FR-15, ADR-004 решение 35): блок «Оценка», затем
/// реплики по времени. Основной формат данных остаётся transcript.json, этот файл только вид.
public enum TranscriptMarkdown {
    public static let fileName = "transcript.md"
    /// Подряд идущие реплики одного говорящего склеиваются, если пауза между ними не больше этой.
    public static let mergeGapMs = 3000
    /// Реплики с уверенностью ниже этой стоит проверить по звуку (часто это «Спасибо.» на шуме).
    public static let lowConfidence = 0.5

    /// Пишет transcript.md в папку записи и возвращает его адрес.
    @discardableResult
    public static func write(_ transcript: Transcript, meta: SessionMetadata?, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        let text = render(transcript, title: meta.map { SessionStore.displayTitle(startedAt: $0.startedAt) } ?? directory.lastPathComponent,
                          durationSeconds: meta?.system?.durationSeconds, multipleVoices: meta?.multipleVoices ?? false,
                          audioDeletedAt: meta?.audioDeleted == true ? meta?.audioDeletedAt : nil)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    public static func render(_ transcript: Transcript, title: String,
                              durationSeconds: Double? = nil, multipleVoices: Bool = false,
                              audioDeletedAt: Date? = nil) -> String {
        let segments = transcript.segments.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
        let labels = Dictionary(transcript.speakers.map { ($0.id, $0.displayName ?? $0.label) },
                                uniquingKeysWith: { first, _ in first })
        func label(_ id: String?) -> String {
            guard let id else { return "Не определён" }
            return labels[id] ?? (id == TranscriptSpeaker.meId ? "Я" : id)
        }
        let speakerOf = Dictionary(segments.map { ($0.id, $0.speakerId) }, uniquingKeysWith: { first, _ in first })

        var lines: [String] = ["# \(title)", ""]
        let seconds = durationSeconds ?? Double(segments.map(\.endMs).max() ?? 0) / 1000
        lines.append("Длительность \(Int((seconds / 60).rounded())) мин, реплик \(segments.count). "
                     + "Время от начала записи (как в mixed.m4a), «перебивание: X» — в это время говорил и X.")
        lines.append("")

        // Оценка: то, что программа знает сама, и поля, которые заполняет пользователь
        let counts = Dictionary(grouping: segments, by: \.speakerId).mapValues(\.count)
        let others = transcript.speakers.filter { $0.id != TranscriptSpeaker.meId && counts[$0.id] != nil }
        var perSpeaker = transcript.speakers.compactMap { s in counts[s.id].map { "\(label(s.id)) \($0)" } }
        if let unknown = counts[nil] { perSpeaker.append("без говорящего \(unknown)") }
        let low = segments.filter { $0.confidence < lowConfidence }.count
        let average = segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Double(segments.count)
        var notes = ["перебиваний \(segments.filter { !$0.overlapWith.isEmpty }.count)"]
        if multipleVoices { notes.append("несколько голосов в комнате: «Я» тоже размечен") }
        if transcript.diarization == nil { notes.append("разметки говорящих нет") }
        lines += ["## Оценка", ""]
        if let audioDeletedAt { lines.append(audioDeletedLine(audioDeletedAt)) }   // FR-11: видно, что аудио удалено
        lines += [
            "- Пригодность текста (пригоден / пригоден после правки / непригоден): ___. "
                + "Средняя уверенность распознавания \(Int((average * 100).rounded()))%, "
                + "реплик с уверенностью ниже \(Int(lowConfidence * 100))%: \(low) — их стоит проверить по звуку.",
            "- Собеседников по разметке: \(others.count) (кроме «Я»). Один человек может быть разбит на несколько номеров. "
                + "Сколько говорило на самом деле: ___.",
            "- Реплик по говорящим: \(perSpeaker.joined(separator: ", ")).",
            "- Замечания: \(notes.joined(separator: "; ")). Ваши: ___.",
            "",
            "## Текст",
            "",
        ]

        // Блоки: подряд идущие реплики одного говорящего с паузой не больше mergeGapMs
        var blocks: [[TranscriptSegment]] = []
        for s in segments {
            if let last = blocks.last?.last, last.speakerId == s.speakerId, s.startMs - last.endMs <= mergeGapMs {
                blocks[blocks.count - 1].append(s)
            } else {
                blocks.append([s])
            }
        }
        for block in blocks {
            let speaker = block[0].speakerId
            var withWhom: [String] = []
            for id in block.flatMap(\.overlapWith) {
                guard let other = speakerOf[id], other != speaker else { continue }
                let name = label(other)
                if !withWhom.contains(name) { withWhom.append(name) }
            }
            let mark = withWhom.isEmpty ? "" : "_(перебивание: \(withWhom.joined(separator: ", ")))_ "
            let text = block.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            lines.append("**[\(clock(block[0].startMs))] \(label(speaker)):** \(mark)\(text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Первая строка блока «Оценка» после удаления аудио по сроку (FR-11, ADR-006 решение 13).
    static func audioDeletedLine(_ date: Date) -> String {
        "- \(AudioRetention.markText) (\(AudioRetention.dateText(date)))."
    }

    /// Отметка уже стоит: новая «Аудио удалено (…)» или отметка E5 «Аудио удалено по сроку хранения (…)».
    static func hasAudioDeletedMark(_ markdown: String) -> Bool {
        markdown.contains("- \(AudioRetention.markText) (") || markdown.contains(AudioRetention.legacyMarkText)
    }

    /// Вставляет отметку об удалении аудио в готовый transcript.md, не перерисовывая файл:
    /// поля «Оценки», заполненные пользователем, сохраняются. Повторная вставка ничего не меняет.
    public static func markAudioDeleted(_ markdown: String, at date: Date) -> String {
        guard !hasAudioDeletedMark(markdown) else { return markdown }
        let line = audioDeletedLine(date) + "\n"
        for heading in ["## Оценка\n\n", "## Оценка\n"] {
            if let range = markdown.range(of: heading) {
                var text = markdown
                text.insert(contentsOf: line, at: range.upperBound)
                return text
            }
        }
        return "## Оценка\n\n" + line + "\n" + markdown   // блока нет (файл правили вручную): отметка в начало
    }

    /// мм:сс от начала записи; после часа минуты продолжают расти (62:05).
    static func clock(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
