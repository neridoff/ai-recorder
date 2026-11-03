import Foundation

/// Строки отчёта о разметке для CLI: говорящие, перебивания, скорость и сверка с Labels.txt.
public enum DiarizationSummary {
    public static let labelsFileName = "Labels.txt"

    public static func lines(transcript: Transcript, meta: SessionMetadata?, directory: URL) -> [String] {
        var lines: [String] = []
        let bySpeaker = Dictionary(grouping: transcript.segments, by: { $0.speakerId ?? "—" }).mapValues(\.count)
        let speakers = transcript.speakers.map { "\($0.label) \(bySpeaker[$0.id] ?? 0)" }
        let unknown = bySpeaker["—"].map { ", без говорящего \($0)" } ?? ""
        lines.append("  реплик по говорящим: \(speakers.joined(separator: ", "))\(unknown)")
        lines.append("  перебиваний (реплик с overlapWith): \(transcript.segments.filter { !$0.overlapWith.isEmpty }.count)")
        if let d = meta?.diarization {
            lines.append(String(format: "  разметка: %.1f с на %.1f мин звука, %.0f× быстрее реального времени",
                                d.processingSeconds, d.audioSeconds / 60, d.realtimeFactor ?? 0))
            if d.audioSeconds > 0 {
                lines.append(String(format: "  оценка: час записи ≈ %.1f мин разметки", d.processingSeconds * 3600 / d.audioSeconds / 60))
            }
        }
        let labelsURL = directory.appendingPathComponent(labelsFileName)
        if let text = try? String(contentsOf: labelsURL, encoding: .utf8) {
            let r = DiarizationEvaluation.evaluate(labels: ReferenceLabel.parseAudacity(text), segments: transcript.segments)
            let othersCorrect = r.correct - r.meCorrect
            // Критерий B (ADR-004 решение 33): чистота кластеров и лимит кластеров на собеседника
            lines.append(String(format: "  FR-05 по %@ (критерий B): %@ — чистота %.1f%% (%d из %d, норма ≥ %.0f%%), кластеров %d на %d собеседников = %.1f на человека (лимит %d)",
                                labelsFileName, r.meetsCriterion ? "выполнен" : "НЕ выполнен",
                                r.purity * 100, r.correctManyToOne, r.total,
                                DiarizationEvaluation.purityThreshold * 100, r.clusters, r.names,
                                r.clustersPerSpeaker, DiarizationEvaluation.maxClustersPerSpeaker))
            lines.append(String(format: "    «я» на «Я»: %d из %d; собеседники после сопоставления: %d из %d; больше всего кластеров у одного человека: %d; меток без реплики %d",
                                r.meCorrect, r.meTotal, r.othersCorrectManyToOne, r.othersTotal,
                                r.maxClustersOfOneSpeaker, r.unmatched))
            lines.append(String(format: "    справка, строгий 1 к 1: %d из %d = %.1f%% (собеседники %d из %d)",
                                r.correct, r.total, r.accuracy * 100, othersCorrect, r.othersTotal))
            let mapping = r.mapping.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            lines.append("    сопоставление 1 к 1: \(mapping.joined(separator: ", "))")
        }
        return lines
    }
}
