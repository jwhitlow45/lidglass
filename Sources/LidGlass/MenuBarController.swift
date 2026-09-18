import AppKit
import Combine

/// The quiet menu bar item: an icon, optionally the live lid angle, and the few controls
/// worth reaching without opening the settings window.
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = Settings.shared
    private let settingsWindow: SettingsWindowController
    private let enabledItem = NSMenuItem(title: "Effect enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private var cancellables = Set<AnyCancellable>()
    private var shownAngle: Int?

    init(controller: AppController, settingsWindow: SettingsWindowController) {
        self.settingsWindow = settingsWindow

        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "LidGlass")
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LidGlass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        settings.$isEnabled.sink { [weak self] enabled in
            self?.enabledItem.state = enabled ? .on : .off
        }.store(in: &cancellables)

        settings.$showsAngleInMenuBar.sink { [weak self] shows in
            guard let self, !shows else { return }
            self.statusItem.button?.title = ""
            self.shownAngle = nil
        }.store(in: &cancellables)

        controller.onAngleChange = { [weak self] angle, isAvailable in
            guard let self, self.settings.showsAngleInMenuBar, isAvailable, Int(angle) != self.shownAngle else { return }
            self.shownAngle = Int(angle)
            self.statusItem.button?.title = " \(Int(angle))°"
        }
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
