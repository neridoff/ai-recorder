import AppKit
import os
import RecorderCore

/// Обновляет строки открытого меню напрямую (FR-16, E4.1 задача 1). MenuBarExtra в стиле
/// .menu строит NSMenu при открытии и не перерисовывает его, пока меню открыто, даже если
/// таймер работает в режиме .common. Поэтому таймер записи и процент обработки меняют
/// заголовок NSMenuItem сами; при следующем открытии SwiftUI строит меню заново из состояния.
@MainActor
final class LiveMenu {
    private weak var menu: NSMenu?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: RecorderLog.subsystem, category: "menu")
    /// Меню открыто: обновить кеш списка «Записи без результата» (ADR-006 решение 8).
    var onOpen: (() -> Void)?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            // object: открытое меню (для меню-бара приложения это главное меню, его не трогаем)
            guard let menu = note.object as? NSMenu, menu !== NSApp.mainMenu else { return }
            MainActor.assumeIsolated {
                // подменю списка записей тоже присылают это уведомление: держим верхнее меню
                guard self?.menu == nil else { return }
                self?.menu = menu
                self?.onOpen?()
                self?.log.debug("Меню открыто: строк \(menu.items.count)")
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                if self?.menu === menu { self?.menu = nil }
            }
        })
    }

    /// Меняет заголовок первой строки, которая начинается с одного из префиксов.
    /// Меню закрыто или строки нет: ничего не делает.
    func set(_ title: String, replacingLineStartingWith prefixes: [String]) {
        guard let menu else { return }
        let item = menu.items.first { item in prefixes.contains { item.title.hasPrefix($0) } }
        guard let item, item.title != title else { return }
        if let attributed = item.attributedTitle, attributed.length > 0 {
            // SwiftUI может задать attributedTitle: сохраняем его шрифт и цвет
            item.attributedTitle = NSAttributedString(string: title, attributes: attributed.attributes(at: 0, effectiveRange: nil))
        }
        item.title = title
    }
}
