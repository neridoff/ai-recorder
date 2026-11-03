import XCTest
@testable import RecorderCore

/// Список «Записи без результата» (E5.1, ADR-006 решение 8).
final class UnfinishedRecordingsTests: XCTestCase {
    var root: URL!
    var store: SessionStore { SessionStore(root: root) }
    let policy = AudioRetention.Policy(compressedDays: 7, rawDays: 7, startedAt: nil)
    let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ d: Int, _ h: Int, _ m: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    private func record(_ state: TranscriptionState, error: String? = nil) -> TranscriptionRecord {
        TranscriptionRecord(status: state, progress: 1, chunksDone: 1, chunksTotal: 1, startedAt: Date(), finishedAt: nil,
                            audioSeconds: 0, processingSeconds: 0, modelVersion: "m", transcriptFile: "transcript.json", error: error)
    }

    private func diarization(_ state: TranscriptionState, error: String? = nil) -> DiarizationRecord {
        DiarizationRecord(status: state, progress: 1, startedAt: Date(), finishedAt: nil, audioSeconds: 0, processingSeconds: 0,
                          modelVersion: "m", speakers: 1, micDiarized: false, error: error)
    }

    /// Запись с сырыми дорожками; change настраивает session.json, segments: реплик в transcript.json.
    @discardableResult
    private func make(_ started: Date, minutes: Double = 25, segments: Int? = nil, md: Bool = true,
                      _ change: (inout SessionMetadata) -> Void = { _ in }) throws -> URL {
        let dir = try store.createSessionDirectory(startedAt: started)
        var meta = SessionMetadata.new(startedAt: started)
        meta.status = .completed
        var system = TrackMetadata(file: "system.caf", sampleRate: 48_000, channels: 2, deviceName: "t")
        system.durationSeconds = minutes * 60
        meta.system = system
        meta.mic = TrackMetadata(file: "mic.caf", sampleRate: 48_000, channels: 1, deviceName: "t")
        change(&meta)
        try store.write(meta, to: dir)
        for name in ["system.caf", "mic.caf"] { try Data("caf".utf8).write(to: dir.appendingPathComponent(name)) }
        if let segments {
            let t = Transcript(schemaVersion: 1, sessionId: "s", modelVersion: "m", language: "ru", systemVAD: true,
                               createdAt: started, updatedAt: started,
                               chunks: [TranscriptChunk(track: .system, index: 0, startSample: 0, endSample: 1, done: true)],
                               segments: (0..<segments).map {
                                   TranscriptSegment(id: "\($0)", sessionId: "s", track: .system, speakerId: nil, startMs: 0,
                                                     endMs: 1, text: "x", language: "ru", confidence: 1, modelVersion: "m")
                               }, speakers: [])
            try SessionMetadata.encoder.encode(t).write(to: dir.appendingPathComponent(Transcript.fileName))
            if md { try Data("# x".utf8).write(to: dir.appendingPathComponent(TranscriptMarkdown.fileName)) }
        }
        return dir
    }

    private func scan(recording: URL? = nil, policy: AudioRetention.Policy? = nil) -> [UnfinishedRecording] {
        UnfinishedRecordings.scan(store: store, policy: policy ?? self.policy, recording: recording)
    }

    func testEachReason() throws {
        let cancelled = TranscriptionError.cancelled.localizedDescription
        try make(date(1, 9, 0)) { $0.transcription = self.record(.failed, error: "whisper упал") }
        try make(date(1, 10, 0), segments: 2) { $0.transcription = self.record(.done); $0.diarization = self.diarization(.failed, error: "x") }
        try make(date(1, 11, 0)) { $0.transcription = self.record(.failed, error: cancelled) }
        try make(date(1, 12, 0))
        try make(date(1, 13, 0)) { $0.status = .recovered }
        try make(date(1, 14, 0), segments: 0) { $0.transcription = self.record(.done) }
        try make(date(1, 15, 0)) { $0.transcription = self.record(.running) }
        try make(date(1, 16, 0), segments: 2) {
            $0.transcription = self.record(.done)
            $0.diarization = self.diarization(.failed, error: DiarizationError.cancelled.localizedDescription)
        }

        let reasons = scan().reversed().map(\.reason)

        XCTAssertEqual(reasons, [.transcriptionFailed, .diarizationFailed, .cancelled, .notStarted, .recovered,
                                 .emptyResult, .transcriptionFailed, .cancelled])
        XCTAssertEqual(reasons.map(\.text).prefix(6), ["ошибка расшифровки", "ошибка разметки", "отменена", "не запускалась",
                                                       "восстановлена после сбоя", "пустой результат"])
    }

    /// Случай со скриншота 03.11.2026: 3 с без речи, 0 чанков, разметка упала с «нет готовой расшифровки».
    func testRecordingWithoutSpeechAndFailedDiarizationIsEmptyResult() throws {
        try make(date(3, 10, 57), minutes: 0.05, segments: 0, md: false) {
            $0.transcription = self.record(.done)
            $0.diarization = self.diarization(.failed, error: DiarizationError.noTranscript.localizedDescription)
        }
        XCTAssertEqual(scan().map(\.reason), [.emptyResult])
        XCTAssertEqual(scan().first?.row(), "03.11 10:57, <1 мин, пустой результат, удалится 10.11")
    }

    func testRecordingsWithResultDeletedAudioCompressionFailureOrRecordingAreExcluded() throws {
        let processed: (inout SessionMetadata) -> Void = {
            $0.transcription = self.record(.done)
            $0.diarization = self.diarization(.done)
        }
        try make(date(1, 9, 0), segments: 3, processed)                                        // результат есть
        try make(date(1, 10, 0), segments: 3) { processed(&$0)                                 // только сбой сжатия
            $0.compression = CompressionRecord(status: .failed, finishedAt: Date(), tracks: [], processingSeconds: 0) }
        try make(date(1, 11, 0)) { $0.audioDeleted = true }                                    // аудио удалено
        try make(date(1, 12, 0)) { $0.status = .recording }                                    // идёт запись
        let live = try make(date(1, 13, 0))                                                    // идёт, ещё со старым статусом
        let compressed = try make(date(1, 14, 0)) { $0.system?.file = "system.m4a"; $0.mic?.file = "mic.m4a" }
        _ = compressed

        XCTAssertEqual(scan(recording: live), [])
    }

    func testOrderNewestFirstLimitAndRows() throws {
        for i in 0..<12 { try make(date(1 + i, 10, 0), minutes: 41) }
        try make(date(20, 9, 30)) { $0.keepAudio = true }

        let list = scan()

        XCTAssertEqual(list.count, 13)
        XCTAssertEqual(list.first?.row(), "20.11 09:30, 25 мин, не запускалась, хранится")
        XCTAssertEqual(list[1].row(), "12.11 10:00, 41 мин, не запускалась, удалится 19.11")
        XCTAssertEqual(list[1].title, "Встреча 12.11.2026 10:00")
        XCTAssertEqual(UnfinishedRecordings.menuLimit, 10)
        XCTAssertEqual(list.map(\.startedAt), list.map(\.startedAt).sorted(by: >))
        let forever = scan(policy: AudioRetention.Policy(compressedDays: 7, rawDays: -1, startedAt: nil))
        XCTAssertTrue(forever.allSatisfy { $0.row().hasSuffix("хранится") })
        let beforePolicy = scan(policy: AudioRetention.Policy(compressedDays: 7, rawDays: 7, startedAt: date(30, 0, 0)))
        XCTAssertTrue(beforePolicy.allSatisfy { $0.deletesAt == nil }, "записи до перехода не удаляются, но в списке есть")
    }

    func testQueuedAndProcessingAreMarkedAndRetryAllGoesOldestFirst() throws {
        let a = try make(date(1, 9, 0))
        let b = try make(date(2, 9, 0))
        let c = try make(date(3, 9, 0))
        let d = try make(date(4, 9, 0))
        let list = scan()
        let activity: (URL) -> UnfinishedRecording.Activity = { dir in
            dir.path == c.path ? .queued : dir.path == d.path ? .processing : .idle
        }

        XCTAssertEqual(list[0].row(activity: .processing), "04.11 09:00, 25 мин, в обработке, удалится 11.11")
        XCTAssertEqual(list[1].row(activity: .queued), "03.11 09:00, 25 мин, в очереди, удалится 10.11")
        XCTAssertEqual(UnfinishedRecordings.retryOrder(list, activity: activity).map(\.path), [a.path, b.path])
    }

    func testOnlyEmptyResultRestartsTranscription() {
        XCTAssertTrue(UnfinishedRecording.Reason.emptyResult.restartsTranscription)
        XCTAssertFalse(UnfinishedRecording.Reason.transcriptionFailed.restartsTranscription)
    }

    /// Замер построения списка (NFR-07): 300 записей в архиве. Порог с запасом, цифра в выводе теста.
    func testScanOfLargeArchiveIsFast() throws {
        for i in 0..<300 { try make(date(1, 0, 0).addingTimeInterval(Double(i) * 3600)) { $0.transcription = self.record(.done); $0.diarization = self.diarization(.done) } }
        let started = Date()
        _ = scan()
        let ms = Date().timeIntervalSince(started) * 1000
        print("Записи без результата: 300 записей за \(Int(ms)) мс")
        XCTAssertLessThan(ms, 2000)
    }
}

/// Замер на копии реального архива (NFR-07): `AIRECORDER_PERF_ARCHIVE=<папка> swift test --filter ArchivePerf`.
final class ArchivePerfTests: XCTestCase {
    func testScanOfArchiveCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["AIRECORDER_PERF_ARCHIVE"] else { throw XCTSkip("нет AIRECORDER_PERF_ARCHIVE") }
        let store = SessionStore(root: URL(fileURLWithPath: path, isDirectory: true))
        let policy = AudioRetention.Policy(compressedDays: 7, rawDays: 7, startedAt: nil)
        for run in 1...3 {
            let started = Date()
            let list = UnfinishedRecordings.scan(store: store, policy: policy)
            print("Архив \(try store.sessionDirectories().count) записей, без результата \(list.count): \(Int(Date().timeIntervalSince(started) * 1000)) мс (прогон \(run))")
        }
    }
}
