import XCTest
import AVFoundation
@testable import RecorderCore

/// E5 (ADR-005): сжатие дорожек после обработки и автоудаление аудио по сроку.
final class AudioRetentionTests: XCTestCase {
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    let policy = AudioRetention.Policy(compressedDays: 7, rawDays: 7, startedAt: nil)

    /// Обработанная запись; compressed: состояние сжатия, сжатие через час после начала.
    private func processed(compressed: CompressionState? = .done) -> SessionMetadata {
        var meta = SessionMetadata.new(startedAt: started, clock: HostClock(numer: 1, denom: 1))
        meta.status = .completed
        meta.transcription = TranscriptionRecord(status: .done, progress: 1, chunksDone: 1, chunksTotal: 1,
                                                 startedAt: started, finishedAt: started, audioSeconds: 60,
                                                 processingSeconds: 1, modelVersion: "m", transcriptFile: "transcript.json")
        meta.diarization = DiarizationRecord(status: .done, progress: 1, startedAt: started, finishedAt: started,
                                             audioSeconds: 60, processingSeconds: 1, modelVersion: "m",
                                             speakers: 1, micDiarized: false)
        meta.compression = compressed.map { CompressionRecord(status: $0, finishedAt: started + 3600, tracks: [], processingSeconds: 0) }
        return meta
    }

    /// Запись без результата: расшифровка упала.
    private func failed() -> SessionMetadata {
        var meta = processed(compressed: nil)
        meta.transcription?.status = .failed
        meta.diarization = nil
        return meta
    }

    private func decide(_ meta: SessionMetadata, hasResult: Bool, policy: AudioRetention.Policy? = nil,
                        at now: Date, active: Bool = false) -> AudioRetention.Decision {
        AudioRetention.decide(meta, hasResult: hasResult, policy: policy ?? self.policy, now: now, isActive: active)
    }

    func testCompressedAudioExpiresExactlyNDaysAfterCompressionFinished() {
        let meta = processed()
        let finished = started + 3600
        XCTAssertEqual(decide(meta, hasResult: true, at: finished + 7 * day - 1), .keep(.notExpired))
        XCTAssertEqual(decide(meta, hasResult: true, at: finished + 7 * day), .delete(.compressed))
        // от startedAt срок уже прошёл бы: отсчёт именно от compression.finishedAt
        XCTAssertEqual(decide(meta, hasResult: true, at: started + 7 * day), .keep(.notExpired))
    }

    func testRawAudioWithoutResultExpiresExactlyNDaysAfterStart() {
        let meta = failed()
        XCTAssertEqual(decide(meta, hasResult: false, at: started + 7 * day - 1), .keep(.notExpired))
        XCTAssertEqual(decide(meta, hasResult: false, at: started + 7 * day), .delete(.raw))
    }

    func testEachAllowedValueIsUsedForItsKind() {
        for days in [1, 3, 14, 30, 90] {
            let p = AudioRetention.Policy(compressedDays: days, rawDays: 1, startedAt: nil)
            XCTAssertEqual(decide(processed(), hasResult: true, policy: p, at: started + 3600 + Double(days) * day), .delete(.compressed))
            XCTAssertEqual(decide(processed(), hasResult: true, policy: p, at: started + 3600 + Double(days) * day - 1), .keep(.notExpired))
        }
    }

    func testMinusOneNeverDeletes() {
        let p = AudioRetention.Policy(compressedDays: -1, rawDays: -1, startedAt: nil)
        XCTAssertEqual(decide(processed(), hasResult: true, policy: p, at: started + 4000 * day), .keep(.keepForever))
        XCTAssertEqual(decide(failed(), hasResult: false, policy: p, at: started + 4000 * day), .keep(.keepForever))
        XCTAssertNil(AudioRetention.rawExpiryDate(failed(), policy: p))
    }

    func testCompressionFailureFallsUnderRawRetention() {
        // результат есть, сжатие упало: сырые остаются и удаляются по rawAudioRetentionDays от startedAt
        let meta = processed(compressed: .failed)
        let p = AudioRetention.Policy(compressedDays: 90, rawDays: 3, startedAt: nil)
        XCTAssertEqual(decide(meta, hasResult: true, policy: p, at: started + 3 * day - 1), .keep(.notExpired))
        XCTAssertEqual(decide(meta, hasResult: true, policy: p, at: started + 3 * day), .delete(.raw))
    }

    func testProcessedButNotYetCompressedWaitsForCompression() {
        XCTAssertEqual(decide(processed(compressed: nil), hasResult: true, at: started + 400 * day), .keep(.awaitingCompression))
        // пустой результат: сжатия не будет, действует срок сырого аудио
        XCTAssertEqual(decide(processed(compressed: nil), hasResult: false, at: started + 7 * day), .delete(.raw))
    }

    func testKeepAudioFlagProtectsBothKinds() {
        var meta = processed()
        meta.keepAudio = true
        XCTAssertEqual(decide(meta, hasResult: true, at: started + 400 * day), .keep(.keepAudioFlag))
        var raw = failed()
        raw.keepAudio = true
        XCTAssertEqual(decide(raw, hasResult: false, at: started + 400 * day), .keep(.keepAudioFlag))
        XCTAssertNil(AudioRetention.rawExpiryDate(raw, policy: policy))
    }

    func testRecordingQueuedAndProcessingAreNeverTouched() {
        var recording = failed()
        recording.status = .recording
        XCTAssertEqual(decide(recording, hasResult: false, at: started + 400 * day), .keep(.active))
        XCTAssertEqual(decide(failed(), hasResult: false, at: started + 400 * day, active: true), .keep(.active))
    }

    func testRecordingsBeforePolicyStartAreNotDeleted() {
        let p = AudioRetention.Policy(compressedDays: 1, rawDays: 1, startedAt: started + 1)
        XCTAssertEqual(decide(processed(), hasResult: true, policy: p, at: started + 400 * day), .keep(.beforePolicy))
        XCTAssertEqual(decide(failed(), hasResult: false, policy: p, at: started + 400 * day), .keep(.beforePolicy))
        XCTAssertNil(AudioRetention.rawExpiryDate(failed(), policy: p), "в списке такая запись «хранится»")
        let after = AudioRetention.Policy(compressedDays: 1, rawDays: 1, startedAt: started)
        XCTAssertEqual(decide(failed(), hasResult: false, policy: after, at: started + day), .delete(.raw), "startedAt == дата перехода: правило действует")
    }

    func testAlreadyDeletedAudioIsSkipped() {
        var meta = processed()
        meta.audioDeleted = true
        XCTAssertEqual(decide(meta, hasResult: true, at: started + 400 * day), .keep(.alreadyDeleted))
    }

    func testSettingsDefaultsNumbersStringsAndUnknownValues() {
        let defaults = UserDefaults(suiteName: "StorageSettingsTests-\(UUID().uuidString)")!
        let settings = StorageSettings(defaults)
        XCTAssertEqual(settings.compressedAudioRetentionDays, 7)
        XCTAssertEqual(settings.rawAudioRetentionDays, 7)
        XCTAssertTrue(settings.autoProcessOnStop)
        XCTAssertTrue(settings.notifyOnDone)
        XCTAssertEqual(settings.transcriptionLanguage, "ru")
        XCTAssertEqual(settings.recordingsRoot, SessionStore.defaultRoot)
        defaults.set(30, forKey: StorageSettings.compressedDaysKey)
        XCTAssertEqual(settings.compressedAudioRetentionDays, 30)
        defaults.set(-1, forKey: StorageSettings.rawDaysKey)
        XCTAssertEqual(settings.rawAudioRetentionDays, -1)
        // аргумент запуска приходит строкой
        defaults.set("14", forKey: StorageSettings.compressedDaysKey)
        XCTAssertEqual(settings.compressedAudioRetentionDays, 14)
        defaults.set(" 1 ", forKey: StorageSettings.rawDaysKey)
        XCTAssertEqual(settings.rawAudioRetentionDays, 1)
        for bad: Any in [45, 0, -2, "месяц", "0", "7дней"] {
            defaults.set(bad, forKey: StorageSettings.compressedDaysKey)
            XCTAssertEqual(settings.compressedAudioRetentionDays, 7, "\(bad)")
        }
        defaults.set("de", forKey: StorageSettings.languageKey)
        XCTAssertEqual(settings.transcriptionLanguage, "ru")
        defaults.set("auto", forKey: StorageSettings.languageKey)
        XCTAssertEqual(settings.transcriptionLanguage, "auto")
        defaults.set(false, forKey: StorageSettings.autoProcessKey)
        XCTAssertFalse(settings.autoProcessOnStop)
        // старый ключ E5 не читается
        defaults.removeObject(forKey: StorageSettings.compressedDaysKey)
        defaults.set(45, forKey: "retentionDays")
        XCTAssertEqual(settings.compressedAudioRetentionDays, 7)
    }

    func testPolicyStartIsWrittenOnceOnFirstLaunch() {
        let defaults = UserDefaults(suiteName: "StorageSettingsTests-\(UUID().uuidString)")!
        let settings = StorageSettings(defaults)
        XCTAssertNil(settings.retentionPolicyStartedAt)
        XCTAssertEqual(settings.ensureRetentionPolicyStarted(now: started), started)
        XCTAssertEqual(settings.ensureRetentionPolicyStarted(now: started + day), started)
        XCTAssertEqual(settings.retentionPolicy.startedAt, started)
        // аргумент запуска для проверок на копии приходит строкой
        defaults.set("2020-01-01T00:00:00Z", forKey: StorageSettings.policyStartedKey)
        XCTAssertEqual(settings.retentionPolicyStartedAt, Date(timeIntervalSince1970: 1_577_836_800))
    }

    func testNeedsCompressionOnlyAfterProcessingAndUntilDone() {
        XCTAssertTrue(AudioCompression.needsCompression(processed(compressed: nil)))
        XCTAssertTrue(AudioCompression.needsCompression(processed(compressed: .failed)))   // повтор при следующей проверке
        XCTAssertFalse(AudioCompression.needsCompression(processed(compressed: .done)))
        var unprocessed = processed(compressed: nil)
        unprocessed.diarization = nil
        XCTAssertFalse(AudioCompression.needsCompression(unprocessed))
        var deleted = processed(compressed: nil)
        deleted.audioDeleted = true
        XCTAssertFalse(AudioCompression.needsCompression(deleted))
    }
}

final class AudioStorageFileTests: XCTestCase {
    var root: URL!
    var dir: URL!
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    var store: SessionStore { SessionStore(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dir = root.appendingPathComponent("2027-01-15_10-00-00")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Шум: у сжатого файла есть что кодировать, а длину можно сверить.
    private func writeNoise(_ name: String, rate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(rate * seconds)
        let file = try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = Float.random(in: -0.2...0.2) }
        }
        try file.write(from: buffer)
    }

    /// Обработанная запись: system 48 кГц стерео и mic 24 кГц моно, по 3 с, как пишет E1.
    @discardableResult
    private func makeProcessedSession(in dir: URL? = nil) throws -> SessionMetadata {
        let dir = dir ?? self.dir!
        let saved = self.dir
        self.dir = dir
        defer { self.dir = saved }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeNoise("system.caf", rate: 48_000, channels: 2, seconds: 3)
        try writeNoise("mic.caf", rate: 24_000, channels: 1, seconds: 3)
        var meta = SessionMetadata.new(startedAt: started, clock: HostClock(numer: 1, denom: 1))
        meta.schemaVersion = 4
        meta.keepAudio = nil   // запись до E5: поля нет
        meta.status = .completed
        var system = TrackMetadata(file: "system.caf", sampleRate: 48_000, channels: 2, deviceName: "Test")
        system.framesWritten = 144_000
        system.durationSeconds = 3
        var mic = TrackMetadata(file: "mic.caf", sampleRate: 24_000, channels: 1, deviceName: "Test")
        mic.framesWritten = 72_000
        mic.durationSeconds = 3
        meta.system = system
        meta.mic = mic
        meta.transcription = TranscriptionRecord(status: .done, progress: 1, chunksDone: 1, chunksTotal: 1,
                                                 startedAt: started, finishedAt: started, audioSeconds: 6,
                                                 processingSeconds: 1, modelVersion: "m", transcriptFile: "transcript.json")
        meta.diarization = DiarizationRecord(status: .done, progress: 1, startedAt: started, finishedAt: started,
                                             audioSeconds: 3, processingSeconds: 1, modelVersion: "m",
                                             speakers: 1, micDiarized: false)
        try SessionStore(root: root).write(meta, to: dir)
        return meta
    }

    /// transcript.json с `segments` репликами и transcript.md: результат для проверки перед сжатием.
    private func writeResult(segments: Int, in dir: URL? = nil) throws {
        let dir = dir ?? self.dir!
        let t = Transcript(schemaVersion: 1, sessionId: dir.lastPathComponent, modelVersion: "w", language: "ru",
                           systemVAD: true, createdAt: started, updatedAt: started,
                           chunks: [TranscriptChunk(track: .system, index: 0, startSample: 0, endSample: 48_000, done: true)],
                           segments: (0..<segments).map {
                               TranscriptSegment(id: "s\($0)", sessionId: dir.lastPathComponent, track: .system, speakerId: nil,
                                                 startMs: $0 * 1000, endMs: $0 * 1000 + 500, text: "реплика", language: "ru",
                                                 confidence: 1, modelVersion: "w")
                           }, speakers: [])
        try SessionMetadata.encoder.encode(t).write(to: dir.appendingPathComponent(Transcript.fileName))
        try Data("# Встреча\n\n## Оценка\n\n- Пригодность текста: ___.\n\n## Текст\n".utf8)
            .write(to: dir.appendingPathComponent(TranscriptMarkdown.fileName))
    }

    private let policy0 = AudioRetention.Policy(compressedDays: 1, rawDays: 1, startedAt: nil)

    private func exists(_ name: String, in dir: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (dir ?? self.dir).appendingPathComponent(name).path)
    }

    private func size(_ name: String) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
        return (attrs[.size] as! NSNumber).int64Value
    }

    private func hiddenFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
    }

    // MARK: Сжатие

    func testCompressionReplacesTracksWithAACAndUpdatesSessionJson() throws {
        try makeProcessedSession()

        let record = try AudioCompression.compress(directory: dir, store: store, now: started + 10)

        XCTAssertEqual(record.status, .done)
        XCTAssertFalse(exists("system.caf"))
        XCTAssertFalse(exists("mic.caf"))
        XCTAssertTrue(exists("system.m4a"))
        XCTAssertTrue(exists("mic.m4a"))
        XCTAssertEqual(try hiddenFiles(), [], "временные файлы и блокировка убраны")
        let meta = try store.read(from: dir)
        XCTAssertEqual(meta.system?.file, "system.m4a")
        XCTAssertEqual(meta.mic?.file, "mic.m4a")
        XCTAssertEqual(meta.schemaVersion, 6)
        XCTAssertEqual(meta.keepAudio, false, "поле появляется, чтобы его было видно и можно было поменять вручную")
        XCTAssertEqual(meta.compression, record)
        XCTAssertEqual(record.tracks.map(\.originalFile), ["system.caf", "mic.caf"])
        XCTAssertTrue(record.tracks.allSatisfy { $0.bytes < $0.originalBytes / 5 }, "\(record.tracks)")
        // длина в кадрах сохраняется: таймкоды и сведение считаются по framesWritten
        XCTAssertEqual(try AVAudioFile(forReading: dir.appendingPathComponent("system.m4a")).length, 144_000)
        XCTAssertEqual(try AVAudioFile(forReading: dir.appendingPathComponent("mic.m4a")).length, 72_000)
    }

    /// mixed.m4a пишет обработка (выравнивание) в AAC 128 кбит/с: он сжимается на месте, имя то же.
    func testCompressionReencodesMixedInPlaceAndKeepsItOnLeftoverCleanup() throws {
        try makeProcessedSession()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try autoreleasepool {
            let mixed = try AVAudioFile(forWriting: dir.appendingPathComponent("mixed.m4a"),
                                        settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                   AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000],
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            let source = try AVAudioFile(forReading: dir.appendingPathComponent("system.caf"))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)!
            try source.read(into: buffer)
            try mixed.write(from: buffer)
        }
        let before = try size("mixed.m4a")

        let record = try AudioCompression.compress(directory: dir, store: store, now: started + 10)

        XCTAssertEqual(record.tracks.map(\.track), ["system", "mic", "mixed"])
        let meta = try store.read(from: dir)
        XCTAssertEqual(meta.system?.file, "system.m4a")
        XCTAssertEqual(meta.mic?.file, "mic.m4a", "mixed не меняет имя файла дорожки")
        XCTAssertLessThan(try size("mixed.m4a"), before / 2)
        let mixed = try AVAudioFile(forReading: dir.appendingPathComponent("mixed.m4a"))
        XCTAssertEqual(mixed.length, 144_000)
        XCTAssertEqual(mixed.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC_HE)
        XCTAssertEqual(try hiddenFiles(), [])
        AudioCompression.removeLeftoverOriginals(in: dir, meta: try store.read(from: dir))
        XCTAssertTrue(exists("mixed.m4a"), "у mixed исходник и результат — один файл")
    }

    func testFailedEncodingKeepsOriginalsAndRecordsError() throws {
        try makeProcessedSession()
        let systemBytes = try size("system.caf")
        let micBytes = try size("mic.caf")
        struct Boom: LocalizedError { var errorDescription: String? { "кодер упал" } }

        // system сжимается, mic падает на середине: исходники целы, сжатые половины убраны
        let record = try AudioCompression.compress(directory: dir, store: store, now: started + 10,
                                                   encode: { source, destination, cancelled in
            if source.lastPathComponent == "mic.caf" {
                try Data("обрывок".utf8).write(to: destination)
                throw Boom()
            }
            return try AudioCompression.encodeAAC(source: source, destination: destination, isCancelled: cancelled)
        })

        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(try size("system.caf"), systemBytes)
        XCTAssertEqual(try size("mic.caf"), micBytes)
        XCTAssertFalse(exists("system.m4a"))
        XCTAssertFalse(exists("mic.m4a"))
        XCTAssertEqual(try hiddenFiles(), [])
        let meta = try store.read(from: dir)
        XCTAssertEqual(meta.system?.file, "system.caf")
        XCTAssertEqual(meta.mic?.file, "mic.caf")
        XCTAssertEqual(meta.compression?.status, .failed)
        XCTAssertEqual(meta.compression?.error, "mic.caf: кодер упал")
        XCTAssertEqual(meta.transcription?.status, .done, "обработка текста не отменяется")
        XCTAssertEqual(meta.errors.last?.source, "compression")
    }

    func testCancelledCompressionLeavesNoTraceAndIsRetriedLater() throws {
        try makeProcessedSession()
        XCTAssertThrowsError(try AudioCompression.compress(directory: dir, store: store, now: started + 10,
                                                           isCancelled: { true })) { error in
            XCTAssertEqual(error as? AudioStorageError, .cancelled)
        }
        XCTAssertTrue(exists("system.caf"))
        XCTAssertTrue(exists("mic.caf"))
        XCTAssertFalse(exists("system.m4a"))
        XCTAssertEqual(try hiddenFiles(), [])
        XCTAssertNil(try store.read(from: dir).compression, "отмена не ошибка: сжатие повторится")
    }

    // MARK: Удаление

    func testDeleteAudioRemovesOnlyAudioAndMarksTranscript() throws {
        try makeProcessedSession()
        try AudioCompression.compress(directory: dir, store: store, now: started + 10)
        let keep = ["transcript.json", "Labels.txt", "reviewed.md"]
        for name in keep + ["mixed.m4a"] { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        try Data("# Встреча\n\nДлительность 1 мин.\n\n## Оценка\n\n- Пригодность текста: пригоден.\n\n## Текст\n".utf8)
            .write(to: dir.appendingPathComponent("transcript.md"))
        let now = started + 31 * 86_400

        let removed = try AudioRetention.deleteAudio(in: dir, store: store, now: now)

        XCTAssertEqual(Set(removed), ["system.m4a", "mic.m4a", "mixed.m4a"])
        for name in keep + ["transcript.md", "session.json"] { XCTAssertTrue(exists(name), name) }
        XCTAssertEqual(try hiddenFiles(), [])
        let meta = try store.read(from: dir)
        XCTAssertEqual(meta.audioDeleted, true)
        XCTAssertEqual(meta.audioDeletedAt, now)
        XCTAssertEqual(meta.audioDeletedReason, .retention)
        XCTAssertEqual(meta.schemaVersion, 6)
        let md = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("## Оценка\n\n- Аудио удалено (\(AudioRetention.dateText(now))).\n- Пригодность текста: пригоден."), md)
    }

    func testMaintenanceCompressesThenDeletesExpiredButSparesKeepAudio() throws {
        let other = root.appendingPathComponent("2027-01-15_11-00-00")
        try makeProcessedSession()
        try writeResult(segments: 2)
        try makeProcessedSession(in: other)
        try writeResult(segments: 2, in: other)
        try store.update(other) { $0.keepAudio = true }
        // запись, которая ещё идёт, не трогается
        let recording = root.appendingPathComponent("2027-01-15_12-00-00")
        try makeProcessedSession(in: recording)
        try store.update(recording) { $0.status = .recording; $0.startedAt = self.started + 1 }

        let report = StorageMaintenance.run(store: store, policy: policy0, now: started + 10)
        XCTAssertEqual(report.compressed, [dir.lastPathComponent, other.lastPathComponent])
        XCTAssertEqual(report.audioDeleted, [], "сжатая копия хранится сутки от сжатия")

        let later = StorageMaintenance.run(store: store, policy: policy0, now: started + 10 + 86_400)
        XCTAssertEqual(later.audioDeleted, [dir.lastPathComponent])
        XCTAssertEqual(later.failures, [])
        XCTAssertFalse(exists("system.m4a"))
        XCTAssertEqual(try store.read(from: dir).audioDeletedReason, .retention)
        XCTAssertTrue(exists("system.m4a", in: other))
        XCTAssertTrue(exists("system.caf", in: recording))
        XCTAssertNil(try store.read(from: recording).compression)
    }

    func testEmptyResultIsNotCompressedAndRawExpiresByRawRetention() throws {
        try makeProcessedSession()
        try writeResult(segments: 0)

        let report = StorageMaintenance.run(store: store, policy: policy0, now: started + 10)
        XCTAssertEqual(report.compressed, [])
        XCTAssertEqual(report.emptyResults, [dir.lastPathComponent])
        XCTAssertTrue(exists("system.caf"))
        XCTAssertNil(try store.read(from: dir).compression)

        let expired = StorageMaintenance.run(store: store, policy: policy0, now: started + 86_400)
        XCTAssertEqual(expired.audioDeleted, [dir.lastPathComponent])
        XCTAssertFalse(exists("system.caf"))
        XCTAssertFalse(exists("mic.caf"))
        let meta = try store.read(from: dir)
        XCTAssertEqual(meta.audioDeletedReason, .rawExpired)
        XCTAssertTrue(exists("session.json"))
    }

    func testCompressionFailureKeepsRawUntilRawRetention() throws {
        try makeProcessedSession()
        try writeResult(segments: 1)
        struct Boom: Error {}
        try AudioCompression.compress(directory: dir, store: store, now: started + 10, encode: { _, _, _ in throw Boom() })
        let p = AudioRetention.Policy(compressedDays: 90, rawDays: 3, startedAt: nil)
        // повтор сжатия тоже падает (файлы-заглушки не трогаем): проверяем только решение по сроку
        let meta = try store.read(from: dir)
        XCTAssertEqual(AudioRetention.decide(meta, hasResult: true, policy: p, now: started + 3 * 86_400 - 1), .keep(.notExpired))
        XCTAssertEqual(AudioRetention.decide(meta, hasResult: true, policy: p, now: started + 3 * 86_400), .delete(.raw))
        XCTAssertTrue(exists("system.caf"))
    }

    func testWarningOneDayBeforeRawDeletionIsSentOnce() throws {
        try makeProcessedSession()
        try store.update(dir) { $0.transcription?.status = .failed; $0.diarization = nil }
        var warned: [URL] = []
        let policy = AudioRetention.Policy(compressedDays: 7, rawDays: 3, startedAt: nil)

        _ = StorageMaintenance.run(store: store, policy: policy, now: started + 86_400, warn: { d, _, _ in warned.append(d) })
        XCTAssertEqual(warned, [], "до удаления больше суток")
        let report = StorageMaintenance.run(store: store, policy: policy, now: started + 2 * 86_400, warn: { d, _, _ in warned.append(d) })
        XCTAssertEqual(warned.map(\.lastPathComponent), [dir.lastPathComponent])
        XCTAssertEqual(report.warned, [dir.lastPathComponent])
        XCTAssertEqual(try store.read(from: dir).deletionWarnedAt, started + 2 * 86_400)
        _ = StorageMaintenance.run(store: store, policy: policy, now: started + 2 * 86_400 + 3600, warn: { d, _, _ in warned.append(d) })
        XCTAssertEqual(warned.count, 1, "второй раз не отправляется")
        XCTAssertTrue(exists("system.caf"))
    }

    func testNoWarningForKeepAudioActiveOrProcessedRecordings() throws {
        try makeProcessedSession()
        try store.update(dir) { $0.transcription?.status = .failed; $0.keepAudio = true }
        var warned = 0
        let policy = AudioRetention.Policy(compressedDays: 7, rawDays: 1, startedAt: nil)
        _ = StorageMaintenance.run(store: store, policy: policy, now: started + 3600, warn: { _, _, _ in warned += 1 })
        try store.update(dir) { $0.keepAudio = false }
        _ = StorageMaintenance.run(store: store, policy: policy, now: started + 3600, active: [dir], warn: { _, _, _ in warned += 1 })
        XCTAssertEqual(warned, 0)
    }

    func testCountDeletionsForNewPolicy() throws {
        try makeProcessedSession()
        try writeResult(segments: 1)
        _ = StorageMaintenance.run(store: store, policy: AudioRetention.Policy(compressedDays: 90, rawDays: 90, startedAt: nil), now: started + 10)
        XCTAssertEqual(StorageMaintenance.countDeletions(store: store, policy: policy0, now: started + 10 + 86_400), 1)
        XCTAssertEqual(StorageMaintenance.countDeletions(store: store, policy: policy0, now: started + 3600), 0)
    }

    func testMaintenanceRemovesOriginalLeftAfterCrashBetweenSwitchAndDelete() throws {
        try makeProcessedSession()
        try AudioCompression.compress(directory: dir, store: store, now: started + 10)
        try Data("старый".utf8).write(to: dir.appendingPathComponent("system.caf"))   // сбой до удаления исходника

        _ = StorageMaintenance.run(store: store, policy: AudioRetention.Policy(compressedDays: 30, rawDays: 30, startedAt: nil), now: started + 20)

        XCTAssertFalse(exists("system.caf"))
        XCTAssertTrue(exists("system.m4a"))
    }
}

final class TranscriptMarkdownAudioDeletedTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    func testMarkIsInsertedAsFirstLineOfAssessmentOnce() {
        let md = "# Встреча\n\n## Оценка\n\n- Пригодность: пригоден после правки.\n\n## Текст\n"
        let marked = TranscriptMarkdown.markAudioDeleted(md, at: at)
        XCTAssertEqual(marked, "# Встреча\n\n## Оценка\n\n- Аудио удалено (\(AudioRetention.dateText(at))).\n- Пригодность: пригоден после правки.\n\n## Текст\n")
        XCTAssertEqual(TranscriptMarkdown.markAudioDeleted(marked, at: at + 86_400), marked)
    }

    func testLegacyMarkFromE5IsNotDuplicated() {
        let md = "# Встреча\n\n## Оценка\n\n- Аудио удалено по сроку хранения (01.01.2027).\n- Пригодность: ___.\n"
        XCTAssertEqual(TranscriptMarkdown.markAudioDeleted(md, at: at), md)
    }

    func testRenderShowsMarkWhenAudioDeleted() {
        let transcript = Transcript(schemaVersion: 1, sessionId: "s", modelVersion: "m", language: "ru", systemVAD: true,
                                    createdAt: at, updatedAt: at, chunks: [], segments: [], speakers: [])
        let md = TranscriptMarkdown.render(transcript, title: "Встреча s", audioDeletedAt: at)
        XCTAssertTrue(md.contains("## Оценка\n\n- Аудио удалено (\(AudioRetention.dateText(at))).\n- Пригодность"), md)
        XCTAssertFalse(TranscriptMarkdown.render(transcript, title: "Встреча s").contains("Аудио удалено"))
    }
}
