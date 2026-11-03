import SwiftUI
import AppKit
import RecorderCore
import os

/// Проверка обновлений по нажатию (FR-27, ADR-007). Один GET к api.github.com, без фона и расписания.
/// Приложение ничего не скачивает и не запускает: команду обновления только кладёт в буфер.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking = false
    /// Найденная более новая версия (решение 11); nil, если установлена та же или новее.
    @Published private(set) var availableVersion: String?

    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "update")

    private init() {
        if let saved = defaults.string(forKey: UpdateCheck.availableVersionKey),
           UpdateCheck.isNewer(saved, than: installedVersion) {
            availableVersion = saved
        }
    }

    func check() {
        guard !isChecking else { return }
        guard let url = UpdateCheck.latestReleaseURL() else {
            log.notice("Проверка обновлений: репозиторий не задан")
            UpdateWindow.shared.show(.failed("адрес репозитория не задан в приложении"))
            return
        }
        isChecking = true
        log.notice("Проверка обновлений")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: UpdateCheck.timeout)
        // Только User-Agent и Accept (решение 3): ни cookies, ни кеша, ни других данных
        request.setValue("AI Recorder/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = UpdateCheck.timeout
        config.timeoutIntervalForResource = UpdateCheck.timeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        let installed = installedVersion
        Task {
            let outcome: UpdateCheck.Outcome
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                outcome = UpdateCheck.outcome(status: status, data: data, installed: installed)
            } catch {
                outcome = .failed(Self.reason(error))
            }
            session.finishTasksAndInvalidate()
            finish(outcome)
        }
    }

    /// Пункт «Доступно обновление X.Y.Z»: окно по сохранённым данным, без запроса.
    func showSaved() {
        guard let version = availableVersion else { return }
        let page = defaults.string(forKey: UpdateCheck.availableURLKey)
            .flatMap(URL.init(string:)).flatMap(UpdateCheck.safePage)
        UpdateWindow.shared.show(.available(.init(version: version, pageURL: page), installed: installedVersion))
    }

    private func finish(_ outcome: UpdateCheck.Outcome) {
        isChecking = false
        switch outcome {
        case .available(let release, _):
            log.notice("Проверка обновлений: доступна версия \(release.version, privacy: .public)")
            defaults.set(release.version, forKey: UpdateCheck.availableVersionKey)
            defaults.set(release.pageURL?.absoluteString, forKey: UpdateCheck.availableURLKey)
            availableVersion = release.version
        case .upToDate:
            log.notice("Проверка обновлений: установлена последняя версия")
            defaults.removeObject(forKey: UpdateCheck.availableVersionKey)
            defaults.removeObject(forKey: UpdateCheck.availableURLKey)
            availableVersion = nil
        case .failed(let reason):
            log.notice("Проверка обновлений не удалась: \(reason, privacy: .public)")
        }
        UpdateWindow.shared.show(outcome)
    }

    private static func reason(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .networkConnectionLost?: return "нет подключения к интернету"
        case .timedOut?: return "сервер не ответил за 10 с"
        case .cannotFindHost?, .dnsLookupFailed?: return "сервер не найден"
        default: return error.localizedDescription
        }
    }
}

/// Окно результата проверки (решения 6, 10). Своё NSWindow, как у настроек: приложение без Dock.
@MainActor
final class UpdateWindow {
    static let shared = UpdateWindow()
    private var window: NSWindow?

    func show(_ outcome: UpdateCheck.Outcome) {
        window?.close()
        let hosting = NSHostingController(rootView: UpdateView(outcome: outcome) { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Обновления AI Recorder"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        SettingsWindow.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

struct UpdateView: View {
    let outcome: UpdateCheck.Outcome
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch outcome {
            case .available(let release, let installed):
                Text("Доступна версия \(release.version) (у вас \(installed))").font(.headline)
                Text("Откройте Терминал, вставьте команду из кнопки ниже и нажмите Enter")
                let command = Self.command
                if let hint = command.hint {
                    Text("Команду \(hint).").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(copied ? "Скопировано" : "Скопировать команду") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command.command, forType: .string)
                        copied = true
                    }
                    if let page = release.pageURL {
                        Button("Описание версии") { NSWorkspace.shared.open(page) }
                    }
                    Spacer()
                    Button("Закрыть", action: close).keyboardShortcut(.cancelAction)
                }
            case .upToDate(let installed):
                Text("Установлена последняя версия (\(installed))").font(.headline)
                closeRow
            case .failed(let reason):
                Text("Не удалось проверить обновления").font(.headline)
                Text(reason).foregroundStyle(.secondary)
                closeRow
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var closeRow: some View {
        HStack { Spacer(); Button("Закрыть", action: close).keyboardShortcut(.defaultAction) }
    }

    /// Путь к исходникам из source-path, который пишет install.sh (решение 12).
    private static var command: (command: String, hint: String?) {
        UpdateCheck.updateCommand(sourcePath: try? String(contentsOf: UpdateCheck.sourcePathFile, encoding: .utf8))
    }
}
