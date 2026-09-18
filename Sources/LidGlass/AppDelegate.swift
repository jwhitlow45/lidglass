import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsWindow = SettingsWindowController(controller: controller)
        self.settingsWindow = settingsWindow
        menuBar = MenuBarController(controller: controller, settingsWindow: settingsWindow)
        controller.start()

        // Test hook: hold the fold at a fixed amount so the effect can be inspected
        // without touching the lid.
        if let forced = ProcessInfo.processInfo.environment["LIDGLASS_FORCE_FOLD"], let fold = Double(forced) {
            Settings.shared.simulationFold = min(max(fold, 0), 1)
            Settings.shared.isSimulating = true
        }

        if !ScreenCaptureSource.hasPermission {
            ScreenCaptureSource.requestPermission()
            explainScreenRecording()
        }
        if !controller.sensorIsAvailable {
            explainMissingSensor()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func explainScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "LidGlass needs Screen Recording permission"
        alert.informativeText = """
        The glass is your own screen, so the app has to read it to redraw it. \
        Allow LidGlass in System Settings, Privacy & Security, Screen & System Audio Recording, then relaunch.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func explainMissingSensor() {
        let alert = NSAlert()
        alert.messageText = "No lid angle sensor on this Mac"
        alert.informativeText = """
        This Mac has no continuous lid-angle sensor, so the fold cannot follow the lid. \
        The scrubber in Settings still drives the effect by hand.
        """
        alert.runModal()
    }
}
