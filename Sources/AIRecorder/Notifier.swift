import AppKit
import UserNotifications
import os
import RecorderCore

/// Уведомление macOS по завершении обработки (FR-16). Работает только из AIRecorder.app:
/// без бандла (swift run) UNUserNotificationCenter недоступен, тогда уведомлений нет.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "notify")
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Запрос разрешения: система показывает его один раз, потом возвращает сохранённый ответ.
    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.log.error("Уведомления: \(error.localizedDescription, privacy: .public)")
            } else {
                self.log.notice("Уведомления разрешены: \(granted)")
            }
        }
    }

    /// file: transcript.md, его открывает клик по уведомлению.
    func post(title: String, body: String, file: URL?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let file { content.userInfo = ["file": file.path] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { self.log.error("Уведомление не отправлено: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // Приложение в меню-баре может считаться активным: показываем баннер и тогда
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["file"] as? String {
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
        completionHandler()
    }
}
