import SwiftUI
import AppKit

@main
struct AIRecorderApp: App {
    @StateObject private var controller = RecorderController()

    init() {
        // Без .app (swift run) LSUIElement из встроенного Info.plist не действует: убираем иконку из Dock вручную
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            MenuBarLabel(state: controller.menuBarIcon, frame: controller.iconFrame)
        }
        .menuBarExtraStyle(.menu)
    }
}
