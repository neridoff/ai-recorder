import SwiftUI
import AppKit
import RecorderCore

/// Окно настроек (E5.1, ADR-006 решения 9, 11). Приложение живёт в меню-баре без Dock
/// (LSUIElement, .accessory): окно само не получает фокус, поэтому перед показом приложение
/// активируется явно, а окно выводится на передний план. Своё NSWindow вместо сцены Settings:
/// на macOS 13 у MenuBarExtra нет надёжного способа открыть сцену Settings из меню.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(controller: RecorderController) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Настройки AI Recorder"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        Self.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    static func activate() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: RecorderController
    private var settings: StorageSettings { controller.settings }

    @State private var compressedDays = 7
    @State private var rawDays = 7
    @State private var autoProcess = true
    @State private var notify = true
    @State private var language = "ru"
    @State private var rootPath = ""

    var body: some View {
        Form {
            Section("Хранение") {
                Picker("Хранить сжатое аудио обработанных записей", selection: Binding(
                    get: { compressedDays },
                    set: { change(compressed: true, to: $0, state: $compressedDays) })) {
                    daysOptions
                }
                Picker("Хранить исходное аудио записей без результата", selection: Binding(
                    get: { rawDays },
                    set: { change(compressed: false, to: $0, state: $rawDays) })) {
                    daysOptions
                }
                Text("Записи, сделанные до \(policyStartText), автоматически не удаляются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Обработка") {
                Toggle("Запускать обработку автоматически после «Стоп»", isOn: Binding(
                    get: { autoProcess },
                    set: { autoProcess = $0; settings.autoProcessOnStop = $0 }))
                Picker("Язык расшифровки", selection: Binding(
                    get: { language },
                    set: { language = $0; settings.transcriptionLanguage = $0 })) {
                    Text("Русский").tag("ru")
                    Text("Определять автоматически").tag("auto")
                }
            }
            Section("Уведомления") {
                Toggle("Уведомление по завершении обработки", isOn: Binding(
                    get: { notify },
                    set: { notify = $0; settings.notifyOnDone = $0 }))
                Text("Уведомления об ошибке и о скором удалении аудио приходят всегда.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Папка архива") {
                Text(rootPath).textSelection(.enabled)
                HStack {
                    Button("Выбрать…") { chooseRoot() }
                    Button("По умолчанию") {
                        settings.setRecordingsRoot(nil)
                        rootPath = settings.recordingsRoot.path
                    }
                }
                Text("Новая папка применяется после перезапуска приложения. Существующие записи не переносятся.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 600)   // у Form со стилем .grouped нет своей высоты: без неё окно сжимается до заголовка
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var daysOptions: some View {
        ForEach(StorageSettings.allowedDays, id: \.self) { days in
            Text(days == StorageSettings.keepForever ? "Не удалять" : "\(days) \(dayWord(days))").tag(days)
        }
    }

    private func load() {
        compressedDays = settings.compressedAudioRetentionDays
        rawDays = settings.rawAudioRetentionDays
        autoProcess = settings.autoProcessOnStop
        notify = settings.notifyOnDone
        language = settings.transcriptionLanguage
        rootPath = settings.recordingsRoot.path
    }

    private var policyStartText: String {
        settings.retentionPolicyStartedAt.map { AudioRetention.dateText($0) } ?? "первого запуска этой версии"
    }

    /// Решение 11: если новый срок короче и удалит аудио существующих записей, спрашиваем;
    /// при отказе остаётся прежнее значение. Увеличение и «не удалять» не спрашивают.
    private func change(compressed: Bool, to value: Int, state: Binding<Int>) {
        let old = state.wrappedValue
        guard value != old else { return }
        if Self.effective(value) < Self.effective(old) {
            var policy = settings.retentionPolicy
            if compressed { policy.compressedDays = value } else { policy.rawDays = value }
            let count = StorageMaintenance.countDeletions(store: controller.store, policy: policy,
                                                          active: controller.activeDirectories)
            if count > 0 {
                let alert = NSAlert()
                alert.messageText = "Будет удалено аудио \(count) \(recordWord(count)). Продолжить?"
                alert.informativeText = "Текст расшифровок и session.json останутся."
                alert.addButton(withTitle: "Продолжить")
                alert.addButton(withTitle: "Отмена")
                SettingsWindow.activate()
                guard alert.runModal() == .alertFirstButtonReturn else {
                    state.wrappedValue = old   // Picker перерисуется с прежним значением
                    return
                }
            }
        }
        state.wrappedValue = value
        if compressed { settings.compressedAudioRetentionDays = value } else { settings.rawAudioRetentionDays = value }
        controller.retentionSettingsChanged()
    }

    private static func effective(_ days: Int) -> Int { days == StorageSettings.keepForever ? .max : days }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.recordingsRoot
        SettingsWindow.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setRecordingsRoot(url)
        rootPath = url.path
    }

    private func dayWord(_ n: Int) -> String {
        n % 10 == 1 && n % 100 != 11 ? "день" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "дня" : "дней"
    }

    private func recordWord(_ n: Int) -> String {
        n % 10 == 1 && n % 100 != 11 ? "записи" : "записей"
    }
}
