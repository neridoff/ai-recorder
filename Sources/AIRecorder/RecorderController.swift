import Foundation
import AppKit
import RecorderCore
import WhisperEngine
import SherpaEngine
import os

@MainActor
final class RecorderController: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, paused, stopping }

    /// Обработка последней записи: расшифровка (E3, ADR-004 решение 21), затем разметка
    /// говорящих (E4, решение 8). Запускается сама при «Стоп» (решение 34) или повтором из
    /// списка «Записи без результата» (ADR-006 решение 8).
    enum Transcription: Equatable {
        case none
        case running(Double)
        case diarizing(Double)
        case done(segments: Int, speakers: Int?)
        /// Расшифровка без реплик: сжатия нет, сырое аудио сохранено (ADR-006 решение 1).
        case empty
        case failed(String)

        /// Строка этапа в меню (FR-16); nil, если обработка не идёт.
        var progressTitle: String? {
            switch self {
            case .running(let fraction): return "Расшифровка, \(Int(fraction * 100))%"
            case .diarizing(let fraction): return "Разметка, \(Int(fraction * 100))%"
            default: return nil
            }
        }
        static let progressPrefixes = ["Расшифровка, ", "Разметка, "]
    }

    @Published private(set) var phase: Phase = .idle { didSet { updateIconAnimation() } }
    @Published private(set) var elapsed: TimeInterval = 0 {
        didSet {
            guard phase == .recording else { return }
            liveMenu.set(MenuView.recordingTitle(elapsed), replacingLineStartingWith: [MenuView.recordingPrefix])
        }
    }
    @Published private(set) var live: SessionMetadata?
    @Published private(set) var lastResult: SessionMetadata?
    @Published private(set) var lastDirectory: URL?
    /// Папка, к которой относится `transcription`. Во время новой записи это предыдущая запись.
    @Published private(set) var transcriptionDirectory: URL?
    /// Сколько остановленных записей ждут обработки (решение 42: запись во время обработки).
    @Published private(set) var queuedCount = 0
    @Published private(set) var message: String?
    @Published private(set) var recoveryNote: String?
    @Published private(set) var transcription: Transcription = .none {
        didSet {
            if let title = transcription.progressTitle {
                liveMenu.set(title, replacingLineStartingWith: Transcription.progressPrefixes)
            }
            updateIconAnimation()
        }
    }
    /// Значок «Ошибка» (E4.2): обработка упала не из-за отмены. Сбрасывается новой записью
    /// или новым запуском обработки; текст ошибки в меню остаётся как был.
    @Published private(set) var showsProcessingFailure = false
    /// Кадр анимации «Обработка» (0 или 1), меняется каждые 0,5 с только в этом состоянии.
    @Published private(set) var iconFrame = 0
    var menuBarIcon: MenuBarIconState {
        .resolve(phase: phase, transcription: transcription, showsFailure: showsProcessingFailure)
    }
    /// Флаг «несколько голосов в комнате» текущей или последней записи (ADR-004 решение 3).
    @Published private(set) var multipleVoices = false
    /// «Не удалять аудио этой записи» текущей или последней записи (FR-13, ADR-006 решение 7).
    @Published private(set) var keepAudio = false
    /// Записи без результата (ADR-006 решение 8): кеш, обновляется после обработки,
    /// обслуживания архива и при открытии меню.
    @Published private(set) var unfinished: [UnfinishedRecording] = []
    /// Название обрабатываемой записи для меню: «Встреча дд.мм.гггг чч:мм».
    @Published private(set) var transcriptionTitle: String?

    /// Запись идёт или стоит на паузе: сессия открыта.
    var isRecording: Bool { phase == .recording || phase == .paused }
    var isTranscribing: Bool {
        switch transcription {
        case .running, .diarizing: return true
        default: return false
        }
    }

    /// Настройки (ADR-006 решение 9). Папка архива читается один раз: смена после перезапуска.
    /// `-recordingsRoot <папка>` в аргументах запуска подменяет её на один запуск (проверки на копиях).
    let settings = StorageSettings()
    let store: SessionStore
    private var session: RecordingSession?
    private var ticker: Timer?
    private var iconAnimation: Timer?
    private var startedAt: Date?
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "app")
    private let cancelFlag = CancelFlag()
    /// Записи ждут, пока обработается текущая: этапы идут по одному (R-03), модели в памяти одни.
    @Published private(set) var queue: [URL] = [] { didSet { queuedCount = queue.count } }
    /// Записи, которые повтор начинает заново (пустой результат), а не с последнего чанка.
    private var restartDirs: Set<URL> = []
    /// keepAudio, выбранный для записи, пока её обрабатывают или сжимают: пишется после.
    private var pendingKeepAudio: [URL: Bool] = [:]
    private var unfinishedScan: Task<Void, Never>?
    private let liveMenu = LiveMenu()
    /// Обслуживание архива (E5, ADR-005): сжатие после обработки и удаление аудио по сроку.
    /// Идёт только без записи и обработки (R-03); новая запись или обработка его отменяют.
    private var maintenance: Task<Void, Never>?
    private let maintenanceCancel = CancelFlag()
    private var maintenanceDue = true
    private var maintenanceTimer: Timer?
    private let notifier = Notifier()

    init() {
        store = SessionStore(root: settings.recordingsRoot)
        // ADR-006 решение 10: записи до первого запуска E5.1 автоудалению не подлежат
        settings.ensureRetentionPolicyStarted()
        notifier.requestAuthorization()   // FR-16: система спросит один раз, при первом запуске
        lastDirectory = try? store.sessionDirectories().last
        refreshTranscriptionState()
        refreshUnfinished()
        liveMenu.onOpen = { [weak self] in self?.refreshUnfinished() }
        recoverInterruptedSessions()
        scheduleAutoRecordIfRequested()
        scheduleDailyMaintenance()
        if UserDefaults.standard.bool(forKey: "autoTranscribeLast") {
            // Для проверок: `AIRecorder -autoTranscribeLast YES` расшифровывает последнюю запись
            log.notice("Расшифровка последней записи по аргументу запуска")
            if let dir = lastDirectory { enqueue(dir) }
        }
        runMaintenanceIfIdle()   // при запуске; ждёт, если автозапуск обработки уже идёт
        if UserDefaults.standard.bool(forKey: "openSettings") {
            // Для проверок: `AIRecorder -openSettings YES` открывает окно настроек без клика по меню
            DispatchQueue.main.async { SettingsWindow.shared.show(controller: self) }
        }
    }

    /// Для проверок без клика по меню: `AIRecorder -autoRecordSeconds 90` начинает запись
    /// сразу после запуска и останавливает её через 90 с (тот же путь, что и кнопка).
    private func scheduleAutoRecordIfRequested() {
        let seconds = UserDefaults.standard.double(forKey: "autoRecordSeconds")
        guard seconds > 0 else { return }
        log.notice("Автозапись на \(seconds) с по аргументу запуска")
        Task {
            await start()
            guard phase == .recording else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))   // отмена сна не ошибка записи
            await stop()
        }
    }

    func toggle() {
        switch phase {
        case .idle: Task { await start() }
        case .recording, .paused: Task { await stop() }
        case .starting, .stopping: break
        }
    }

    func togglePause() {
        guard let session else { return }
        switch phase {
        case .recording:
            Task {
                ticker?.invalidate()
                await session.pause(pressedHostTime: HostClock.system.now())
                phase = .paused
                live = session.currentMetadata()
            }
        case .paused:
            Task {
                do {
                    try await session.resume(pressedHostTime: HostClock.system.now())
                    phase = .recording
                    startTicker()
                } catch {
                    message = "Не удалось продолжить запись: \(error.localizedDescription)"
                }
            }
        default: break
        }
    }

    // MARK: Расшифровка

    /// Ставит запись в обработку. Если идёт обработка другой записи, эта ждёт в очереди.
    /// restart: расшифровать заново, а не с последнего готового чанка.
    func enqueue(_ dir: URL, restart: Bool = false) {
        guard dir != session?.directory else { return }   // идущая запись не обрабатывается (R-03)
        if (try? store.read(from: dir))?.audioDeleted == true {
            message = "Аудио этой записи удалено по сроку хранения, расшифровать её нельзя"
            return
        }
        if restart { restartDirs.insert(dir) }
        if isTranscribing || maintenance != nil {
            guard !(isTranscribing && dir == transcriptionDirectory), !queue.contains(dir) else { return }
            queue.append(dir)
            log.notice("В очередь обработки: \(dir.lastPathComponent, privacy: .public)")
            if maintenance != nil {
                // сжатие прерывается, очередь пойдёт сразу после его остановки
                maintenanceCancel.set()
                maintenanceDue = true
            }
            return
        }
        process(dir)
    }

    // MARK: Записи без результата

    /// Пометка строки списка: запись обрабатывается или ждёт в очереди.
    func activity(of dir: URL) -> UnfinishedRecording.Activity {
        if isTranscribing && dir == transcriptionDirectory { return .processing }
        return queue.contains(dir) ? .queued : .idle
    }

    /// «Повторить расшифровку» из подменю записи. Во время записи недоступно (R-03).
    func retry(_ item: UnfinishedRecording) {
        guard !isRecording, activity(of: item.directory) == .idle else { return }
        enqueue(item.directory, restart: item.reason.restartsTranscription)
    }

    /// «Повторить все»: от старых к новым.
    func retryAll() {
        guard !isRecording else { return }
        let restart = Set(unfinished.filter(\.reason.restartsTranscription).map(\.directory))
        for dir in UnfinishedRecordings.retryOrder(unfinished, activity: activity(of:)) {
            enqueue(dir, restart: restart.contains(dir))
        }
    }

    /// «Удалить…» (решение пользователя 03.11.2026): после подтверждения папка записи целиком
    /// уходит в Корзину macOS, вернуть можно оттуда. Запись в очереди или в обработке не удаляется.
    func delete(_ item: UnfinishedRecording) {
        let dir = item.directory
        guard activity(of: dir) == .idle, dir != session?.directory else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить запись \(item.title)?"
        alert.informativeText = "Папка записи со всеми файлами переместится в Корзину. Вернуть её можно из Корзины."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        SettingsWindow.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.moveToTrash(dir)
            log.notice("Запись в Корзину: \(dir.lastPathComponent, privacy: .public)")
        } catch {
            message = "Не удалось удалить запись: \(error.localizedDescription)"
            return
        }
        pendingKeepAudio[dir] = nil
        restartDirs.remove(dir)
        unfinished.removeAll { $0.directory == dir }
        if dir == lastDirectory {
            lastDirectory = try? store.sessionDirectories().last
            refreshTranscriptionState()
        }
        refreshUnfinished()
    }

    func reveal(_ dir: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Пересчитывает список в фоне. Чтение session.json по всему архиву (NFR-07, замер в README).
    func refreshUnfinished() {
        unfinishedScan?.cancel()
        let store = self.store
        let policy = settings.retentionPolicy
        let recording = isRecording ? session?.directory : nil
        unfinishedScan = Task.detached(priority: .utility) {
            let started = Date()
            let list = UnfinishedRecordings.scan(store: store, policy: policy, recording: recording)
            let ms = Date().timeIntervalSince(started) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.unfinished = list
                self.log.debug("Записи без результата: \(list.count), \(String(format: "%.0f", ms), privacy: .public) мс")
            }
        }
    }

    private func process(_ dir: URL) {
        if maintenance != nil {
            // сжатие этой или другой записи прерывается, обработка начнётся сразу после
            maintenanceCancel.set()
            maintenanceDue = true
            if !queue.contains(dir) { queue.insert(dir, at: 0) }
            return
        }
        showsProcessingFailure = false
        message = nil
        transcriptionDirectory = dir
        let title = store.displayTitle(of: dir)
        transcriptionTitle = title
        transcription = .running(0)
        cancelFlag.reset()
        let cancel = cancelFlag
        let store = self.store
        let notifier = self.notifier
        let language = settings.transcriptionLanguage
        let notifyOnDone = settings.notifyOnDone
        let restart = restartDirs.remove(dir) != nil
        Task.detached(priority: .userInitiated) {
            let result: Transcription
            do {
                let engine = try WhisperEngine()
                let job = TranscriptionJob(directory: dir, engine: engine, language: language)
                let transcript = try job.run(restart: restart, progress: { p in
                    Task { @MainActor in
                        if case .running = self.transcription { self.transcription = .running(p.fraction) }
                    }
                }, isCancelled: { cancel.isSet })
                self.log.notice("Расшифровка готова: \(dir.lastPathComponent, privacy: .public), реплик \(transcript.segments.count)")
                guard !transcript.segments.isEmpty else {
                    // Речи нет (тишина, короткая проба): разметке нечего делить, сжатия нет, аудио
                    // остаётся для повтора, запись в списке «Записи без результата» (ADR-006 решение 1)
                    await self.finishProcessing(dir, result: .empty, cancelled: false)
                    if notifyOnDone {
                        notifier.post(title: "Расшифровка пустая",
                                      body: "В записи \(title) не найдено речи, аудио сохранено. Повторить: меню, Записи без результата",
                                      file: nil)
                    }
                    return
                }
                await MainActor.run { self.transcription = .diarizing(0) }
                let diarizer = try SherpaDiarizer()
                let labelled = try DiarizationJob(directory: dir, diarizer: diarizer).run(progress: { p in
                    Task { @MainActor in
                        if case .diarizing = self.transcription { self.transcription = .diarizing(p) }
                    }
                }, isCancelled: { cancel.isSet })
                let speakers = labelled.speakers.filter { $0.id != TranscriptSpeaker.meId }.count
                // Читабельный текст (FR-15, решение 35); основной формат остаётся transcript.json
                let md = try TranscriptMarkdown.write(labelled, meta: try? store.read(from: dir), to: dir)
                result = .done(segments: labelled.segments.count, speakers: speakers)
                self.log.notice("Разметка готова: \(dir.lastPathComponent, privacy: .public), собеседников \(speakers)")
                if notifyOnDone {
                    notifier.post(title: "Готово: реплик \(labelled.segments.count), собеседников \(speakers)",
                                  body: "\(title): \(md.lastPathComponent)", file: md)
                }
            } catch {
                result = .failed(error.localizedDescription)
                self.log.error("Расшифровка не удалась: \(error.localizedDescription, privacy: .public)")
                if !cancel.isSet {
                    // ADR-006 решение 15: текст для человека, подробности в session.json и в меню
                    notifier.post(title: "Ошибка обработки",
                                  body: "Расшифровка записи \(title) не удалась. Повторить: меню, Записи без результата", file: nil)
                }
            }
            await self.finishProcessing(dir, result: result, cancelled: cancel.isSet)
        }
    }

    private func finishProcessing(_ dir: URL, result: Transcription, cancelled: Bool) {
        if case .failed = result { showsProcessingFailure = !cancelled }   // отмена не ошибка
        transcription = result
        if result == .empty { message = "Расшифровка пустая, аудио сохранено" }
        if dir == lastDirectory, !isRecording { refreshFlags() }
        applyPendingKeepAudio()
        maintenanceDue = true   // сжатие после обработки (FR-11), сроки и предупреждения
        refreshUnfinished()
        if !queue.isEmpty { process(queue.removeFirst()) } else { runMaintenanceIfIdle() }
    }

    /// Отменяет текущую обработку; записи из очереди обрабатываются дальше.
    func cancelTranscription() {
        cancelFlag.set()
    }

    /// Во время записи флаг идёт в открытую сессию, после — в session.json последней записи
    /// (действует при следующей разметке).
    func toggleMultipleVoices() {
        let value = !multipleVoices
        if let session {
            session.setMultipleVoices(value)
        } else if let dir = lastDirectory {
            do {
                var meta = try store.read(from: dir)
                meta.multipleVoices = value ? true : nil
                try store.write(meta, to: dir)
            } catch {
                message = "Не удалось сохранить флаг: \(error.localizedDescription)"
                return
            }
        } else {
            return
        }
        multipleVoices = value
    }

    /// «Не удалять аудио этой записи» (ADR-006 решение 7). Во время записи флаг идёт в открытую
    /// сессию и попадает в session.json при остановке, после — в session.json последней записи.
    func toggleKeepAudio() {
        let value = !keepAudio
        if let session {
            session.setKeepAudio(value)
            keepAudio = value
        } else if let dir = lastDirectory {
            setKeepAudio(value, for: dir)
        }
    }

    /// Пишет keepAudio атомарно. Пока запись обрабатывается или идёт обслуживание архива,
    /// они читают и пишут её session.json: значение запоминается и пишется после них.
    func setKeepAudio(_ value: Bool, for dir: URL) {
        if dir == lastDirectory { keepAudio = value }
        if let i = unfinished.firstIndex(where: { $0.directory == dir }) { unfinished[i].keepAudio = value }
        if activity(of: dir) != .idle || maintenance != nil {
            pendingKeepAudio[dir] = value
            return
        }
        do {
            try store.update(dir) { $0.keepAudio = value }
        } catch {
            message = "Не удалось сохранить флаг: \(error.localizedDescription)"
        }
        refreshUnfinished()
    }

    private func applyPendingKeepAudio() {
        for (dir, value) in pendingKeepAudio where activity(of: dir) == .idle && maintenance == nil {
            pendingKeepAudio[dir] = nil
            setKeepAudio(value, for: dir)
        }
    }

    func revealTranscript() {
        guard let dir = transcriptionDirectory ?? lastDirectory else { return }
        let md = dir.appendingPathComponent(TranscriptMarkdown.fileName)
        let file = FileManager.default.fileExists(atPath: md.path) ? md : dir.appendingPathComponent(Transcript.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Состояние по session.json последней записи (после перезапуска приложения).
    private func refreshTranscriptionState() {
        guard !isTranscribing else { return }   // идущая обработка сама обновит состояние
        let meta = refreshFlags()
        transcriptionDirectory = lastDirectory
        transcriptionTitle = lastDirectory.map { store.displayTitle(of: $0) }
        guard let dir = lastDirectory, let meta, let record = meta.transcription else {
            transcription = .none
            return
        }
        switch record.status {
        case .done:
            let transcript = (try? Data(contentsOf: dir.appendingPathComponent(Transcript.fileName)))
                .flatMap { try? SessionMetadata.decoder.decode(Transcript.self, from: $0) }
            let count = transcript?.segments.count ?? 0
            if count == 0, meta.diarization?.status != .done {
                transcription = .empty
                break
            }
            switch meta.diarization?.status {
            case .done?:
                transcription = .done(segments: count, speakers: meta.diarization?.speakers)
            case .failed?, .running?:
                // разметку можно повторить той же кнопкой: готовые чанки расшифровки не пересчитываются
                transcription = .failed("разметка: \(meta.diarization?.error ?? "прервана, её можно продолжить")")
            case nil:
                transcription = .done(segments: count, speakers: nil)
            }
        case .failed: transcription = .failed(record.error ?? "неизвестная ошибка")
        // running без живого процесса: прервано сбоем, продолжится по кнопке
        case .running: transcription = .failed("расшифровка прервана, её можно продолжить")
        }
        // ADR-006 решение 15: «Ошибка» только для свежей ошибки; старые записи без результата
        // видны в списке, а не по значку после перезапуска
        showsProcessingFailure = false
    }

    /// Флаги последней записи из её session.json.
    @discardableResult
    private func refreshFlags() -> SessionMetadata? {
        let meta = lastDirectory.flatMap { try? store.read(from: $0) }
        multipleVoices = meta?.multipleVoices ?? false
        keepAudio = lastDirectory.flatMap { pendingKeepAudio[$0] } ?? meta?.keepAudio ?? false
        return meta
    }

    // MARK: Обслуживание архива

    /// Проверка срока раз в сутки, пока приложение открыто. .common: таймер идёт и при открытом меню.
    private func scheduleDailyMaintenance() {
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.maintenanceDue = true
                self?.runMaintenanceIfIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    /// Сжимает обработанные записи и удаляет аудио старше срока, если нет записи и обработки.
    /// Если сейчас занято, проверка выполнится после обработки (флаг maintenanceDue).
    private func runMaintenanceIfIdle() {
        guard maintenanceDue, maintenance == nil, phase == .idle, !isTranscribing, queue.isEmpty else { return }
        maintenanceDue = false
        maintenanceCancel.reset()
        let cancel = maintenanceCancel
        let store = self.store
        let policy = settings.retentionPolicy
        let notifier = self.notifier
        maintenance = Task.detached(priority: .utility) {
            let report = StorageMaintenance.run(store: store, policy: policy, warn: { dir, meta, _ in
                // ADR-006 решение 6: одно уведомление на запись, затем deletionWarnedAt
                notifier.post(title: "Аудио скоро удалится",
                              body: "Аудио записи \(SessionStore.displayTitle(startedAt: meta.startedAt)) будет удалено через сутки: расшифровка не завершена. Повторить: меню, Записи без результата",
                              file: nil)
            }, isCancelled: { cancel.isSet })
            if !report.compressed.isEmpty || !report.audioDeleted.isEmpty || !report.failures.isEmpty || !report.warned.isEmpty {
                self.log.notice("Архив: сжато \(report.compressed.joined(separator: ", "), privacy: .public) (освобождено \(report.savedBytes / 1_000_000) МБ); аудио удалено по сроку (сжатое \(policy.compressedDays) дн., сырое \(policy.rawDays) дн.): \(report.audioDeleted.joined(separator: ", "), privacy: .public); предупреждения: \(report.warned.joined(separator: ", "), privacy: .public); ошибки: \(report.failures.joined(separator: "; "), privacy: .public)")
            }
            await MainActor.run {
                self.maintenance = nil
                self.applyPendingKeepAudio()
                self.refreshUnfinished()
                if report.cancelled { self.maintenanceDue = true }   // прервано записью или обработкой: повторим позже
                if !self.queue.isEmpty, !self.isTranscribing, !self.isRecording {
                    self.process(self.queue.removeFirst())
                } else {
                    self.runMaintenanceIfIdle()
                }
            }
        }
    }

    /// Новые сроки из окна настроек: проверка сразу, если нет записи и обработки (решение 11).
    func retentionSettingsChanged() {
        maintenanceDue = true
        runMaintenanceIfIdle()
        refreshUnfinished()
    }

    /// Папки, которые нельзя трогать: идущая запись, обработка, очередь.
    var activeDirectories: Set<URL> {
        var dirs = Set(queue)
        if isTranscribing, let dir = transcriptionDirectory { dirs.insert(dir) }
        if let dir = session?.directory { dirs.insert(dir) }
        return dirs
    }

    func openRecordingsFolder() {
        do {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.root)
        } catch {
            message = "Не удалось открыть папку: \(error.localizedDescription)"
        }
    }

    func revealLastSession() {
        guard let lastDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastDirectory])
    }

    // MARK: Старт и стоп

    private func start() async {
        // Момент нажатия фиксируется до любых проверок: от него считается задержка старта (FR-01)
        let pressed = HostClock.system.now()
        phase = .starting
        message = nil

        guard await Permissions.ensureMicrophone() else {
            fail("Нет доступа к микрофону. Разрешите его в Системных настройках и запустите запись снова.")
            Permissions.openMicrophoneSettings()
            return
        }
        guard Permissions.ensureScreenCapture() else {
            fail("Нет разрешения «Запись экрана и системного звука». Включите AI Recorder в Системных настройках и перезапустите приложение.")
            Permissions.openScreenCaptureSettings()
            return
        }

        if maintenance != nil {
            // R-03: сжатие не идёт во время записи; прерванное повторится после обработки
            maintenanceCancel.set()
            maintenanceDue = true
        }
        let session = RecordingSession(store: store, system: SystemAudioCapture(), mic: MicrophoneCapture())
        do {
            try await session.start(startPressedHostTime: pressed)
        } catch {
            lastDirectory = session.directory
            fail("Запись не началась: \(error.localizedDescription)")
            return
        }
        self.session = session
        lastDirectory = session.directory
        startedAt = Date()
        elapsed = 0
        showsProcessingFailure = false   // ошибка прошлой обработки держится до начала записи
        phase = .recording
        // Обработка предыдущей записи продолжается в фоне (решение 42), её строка остаётся в меню
        if multipleVoices { session.setMultipleVoices(true) }   // флаг, включённый до старта
        keepAudio = false   // у новой записи свой флаг
        refreshUnfinished()
        startTicker()
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common: таймер работает и при открытом меню (в режиме .default NSMenu его не запускает)
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Таймер кадров живёт только в состоянии «Обработка». .common: кадры меняются и при открытом меню.
    private func updateIconAnimation() {
        guard menuBarIcon == .processing else {
            iconAnimation?.invalidate()
            iconAnimation = nil
            iconFrame = 0
            return
        }
        guard iconAnimation == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.iconFrame = (self.iconFrame + 1) % MenuBarIconState.processing.frameCount
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconAnimation = timer
    }

    private func stop() async {
        guard let session else { return }
        phase = .stopping
        ticker?.invalidate()
        ticker = nil
        let result = await session.stop()
        self.session = nil
        live = nil
        lastResult = result
        phase = .idle
        message = result.errors.isEmpty ? nil : "Ошибок в записи: \(result.errors.count) (см. session.json)"
        // ADR-004 решение 34: обработка стартует сама после «Стоп» (пауза её не запускает),
        // если не выключена в настройках (autoProcessOnStop); тогда запись ждёт в списке без результата.
        guard settings.autoProcessOnStop, let dir = lastDirectory else {
            log.notice("Запись остановлена, автообработка выключена")
            refreshUnfinished()
            return
        }
        log.notice("Запись остановлена, запускаем обработку")
        enqueue(dir)
    }

    private func tick() {
        guard let startedAt, let session else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        live = session.currentMetadata()
    }

    private func fail(_ text: String) {
        log.error("\(text, privacy: .public)")
        message = text
        phase = .idle
    }

    // MARK: Восстановление

    private func recoverInterruptedSessions() {
        let store = self.store
        Task.detached(priority: .utility) {
            let reports = SessionRecovery(store: store).recoverAll()
            guard !reports.isEmpty else { return }
            let names = reports.map { "\(store.displayTitle(of: $0.directory)) (\($0.status.rawValue))" }
            await MainActor.run {
                self.recoveryNote = "Восстановлено после сбоя: " + names.joined(separator: ", ")
                self.lastDirectory = reports.last?.directory
                self.refreshTranscriptionState()
                self.refreshUnfinished()
            }
        }
    }
}

/// Флаг отмены, который опрашивает whisper.cpp из своего потока.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func reset() { lock.withLock { value = false } }
}
