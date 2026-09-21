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
        // Permission only takes effect on relaunch, so checking once per launch is enough.
        if !ScreenCaptureSource.hasPermission {
            let permissionItem = NSMenuItem(title: "Screen Recording not allowed…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
            permissionItem.target = self
            permissionItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(permissionItem)
            menu.addItem(.separator())
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "LidGlass needs Screen Recording")
        }
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

        // A still lid sends no readings, so turning the angle on shows the latest one.
        settings.$showsAngleInMenuBar.sink { [weak self, weak controller] shows in
            guard let self else { return }
            if shows, let controller, controller.sensorIsAvailable {
                self.showAngle(controller.angle)
            } else {
                self.statusItem.button?.title = ""
                self.shownAngle = nil
            }
        }.store(in: &cancellables)

        controller.onAngleChange = { [weak self] angle, isAvailable in
            guard let self, self.settings.showsAngleInMenuBar, isAvailable else { return }
            self.showAngle(angle)
        }
    }

    private func showAngle(_ angle: Double) {
        guard Int(angle) != shownAngle else { return }
        shownAngle = Int(angle)
        statusItem.button?.title = " \(Int(angle))°"
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
