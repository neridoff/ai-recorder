import SwiftUI
import RecorderCore

struct MenuView: View {
    @ObservedObject var controller: RecorderController
    @ObservedObject var updates = UpdateChecker.shared

    var body: some View {
        Button(primaryTitle) { controller.toggle() }
            .keyboardShortcut("r")
            .disabled(controller.phase == .starting || controller.phase == .stopping)
        if controller.isRecording {
            Button(controller.phase == .paused ? "Продолжить запись" : "Пауза") { controller.togglePause() }
                .keyboardShortcut("p")
        }
        // ADR-004 решение 3: mic тоже размечается, если в комнате несколько человек
        Toggle("Несколько голосов в комнате", isOn: Binding(
            get: { controller.multipleVoices },
            set: { _ in controller.toggleMultipleVoices() }))
            // после записи флаг пишется в session.json, который в это время может читать обработка
            .disabled(!controller.isRecording && controller.isTranscribing)
        // ADR-006 решение 7: защищает и сырые, и сжатые файлы этой записи от удаления по сроку
        Toggle("Не удалять аудио этой записи", isOn: Binding(
            get: { controller.keepAudio },
            set: { _ in controller.toggleKeepAudio() }))
            .disabled(!controller.isRecording && controller.lastDirectory == nil)

        if controller.phase == .paused {
            Text("Пауза, записано: \(Self.format(controller.elapsed))")
        } else if controller.isRecording {
            Text(Self.recordingTitle(controller.elapsed))
            if let live = controller.live {
                Text(Self.offsetLine(live))
                if !live.errors.isEmpty {
                    Text("Ошибок: \(live.errors.count), последняя: \(live.errors.last!.message)")
                }
            }
        } else if let result = controller.lastResult {
            Text("Последняя запись: \(result.status.rawValue), \(Self.format(result.system?.durationSeconds ?? 0))")
            Text(Self.offsetLine(result))
        }

        transcriptionItems
        unfinishedItems

        if let message = controller.message {
            Text(message)
        }
        if let note = controller.recoveryNote {
            Text(note)
        }

        Divider()
        Button("Показать последнюю запись в Finder") { controller.revealLastSession() }
            .disabled(controller.lastDirectory == nil)
        Button("Открыть папку записей") { controller.openRecordingsFolder() }
        Button("Настройки…") { SettingsWindow.shared.show(controller: controller) }
            .keyboardShortcut(",")
        // FR-27, ADR-007: запрос только по нажатию; во время записи и обработки сети нет (NFR-01)
        Button(updates.isChecking ? "Проверка обновлений…" : "Проверить обновления…") { updates.check() }
            .disabled(updates.isChecking || controller.isRecording || controller.isTranscribing)
        if let version = updates.availableVersion {
            Button("Доступно обновление \(version)") { updates.showSaved() }
        }
        Divider()
        Button("Выйти") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(controller.isRecording)
    }

    /// Верхний блок обработки: только состояние и действия над идущей обработкой. Запуск
    /// расшифровки — из списка «Записи без результата» (ADR-006 решение 8), ⌘T убрано.
    @ViewBuilder
    private var transcriptionItems: some View {
        switch controller.transcription {
        case .running, .diarizing:
            Divider()
            // Строку обновляет и LiveMenu, пока меню открыто (FR-16)
            Text(controller.transcription.progressTitle ?? "")
            if let dir = controller.transcriptionDirectory, dir != controller.lastDirectory {
                Text("Обрабатывается запись \(controller.transcriptionTitle ?? dir.lastPathComponent)")
            }
            if controller.queuedCount > 0 {
                Text("В очереди записей: \(controller.queuedCount)")
            }
            actionButtons
        case .done(let segments, let speakers):
            Divider()
            Text(speakers.map { "Готово: реплик \(segments), собеседников \($0)" }
                 ?? "Расшифровка готова: реплик \(segments), без разметки")
            actionButtons
        case .failed(let error):
            Divider()
            Text("Ошибка расшифровки: \(error)")
        case .empty, .none:
            EmptyView()   // «Расшифровка пустая, аудио сохранено» показывает message
        }
    }

    /// Кнопки верхнего блока: только действия над идущей или готовой обработкой.
    enum ProcessingAction: String, CaseIterable {
        case cancel = "Отменить расшифровку"
        case reveal = "Показать расшифровку в Finder"
    }

    static func processingActions(_ transcription: RecorderController.Transcription) -> [ProcessingAction] {
        switch transcription {
        case .running, .diarizing: return [.cancel]
        case .done: return [.reveal]
        case .empty, .failed, .none: return []
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(Self.processingActions(controller.transcription), id: \.self) { action in
            Button(action.rawValue) {
                switch action {
                case .cancel: controller.cancelTranscription()
                case .reveal: controller.revealTranscript()
                }
            }
        }
    }

    /// «Записи без результата (N)»: виден только при N > 0 (ADR-006 решение 8).
    @ViewBuilder
    private var unfinishedItems: some View {
        let list = controller.unfinished
        if !list.isEmpty {
            Divider()
            Text("Записи без результата (\(list.count))")
            ForEach(Array(list.prefix(UnfinishedRecordings.menuLimit)), id: \.directory) { item in
                let activity = controller.activity(of: item.directory)
                Menu(item.row(activity: activity)) {
                    Button("Повторить расшифровку") { controller.retry(item) }
                        .disabled(controller.isRecording || activity != .idle)
                    Button("Показать в Finder") { controller.reveal(item.directory) }
                    Toggle("Не удалять аудио", isOn: Binding(
                        get: { item.keepAudio },
                        set: { controller.setKeepAudio($0, for: item.directory) }))
                    Divider()
                    Button("Удалить…") { controller.delete(item) }
                        .disabled(activity != .idle)
                }
            }
            if list.count > UnfinishedRecordings.menuLimit {
                Button("Ещё \(list.count - UnfinishedRecordings.menuLimit)… открыть папку записей") {
                    controller.openRecordingsFolder()
                }
            }
            let ready = UnfinishedRecordings.retryOrder(list, activity: controller.activity(of:)).count
            Button("Повторить все (\(ready))") { controller.retryAll() }
                .disabled(controller.isRecording || ready == 0)
        }
    }

    private var primaryTitle: String {
        switch controller.phase {
        case .idle: return "Начать запись"
        case .starting: return "Запуск…"
        case .recording, .paused: return "Остановить запись"
        case .stopping: return "Сохранение…"
        }
    }

    /// Строка таймера; при открытом меню её обновляет LiveMenu по префиксу.
    static let recordingPrefix = "Идёт запись: "
    static func recordingTitle(_ elapsed: TimeInterval) -> String { recordingPrefix + format(elapsed) }

    static func offsetLine(_ meta: SessionMetadata) -> String {
        guard let offset = meta.startOffsetMs else { return "Сдвиг mic − system: ждём первые сэмплы" }
        return String(format: "Сдвиг mic − system: %+.1f мс", offset)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
