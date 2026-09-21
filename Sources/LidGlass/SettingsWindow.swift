import AppKit
import SwiftUI
import MetalKit
import ScreenCaptureKit
import ServiceManagement

/// Live material preview: the same renderer and the same settings as the overlay, fed a
/// still of the display instead of a stream.
struct PreviewView: NSViewRepresentable {
    let controller: AppController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        let view: MTKView
        private let renderer: GlassRenderer?
        private let controller: AppController
        private var timer: Timer?

        init(controller: AppController) {
            self.controller = controller
            let device = MTLCreateSystemDefaultDevice()
            let renderer = device.flatMap { GlassRenderer(device: $0) }
            self.renderer = renderer
            view = MTKView(frame: .zero, device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.layer?.isOpaque = false
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.delegate = renderer
            view.preferredFramesPerSecond = 60
            loadStill()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self, let renderer = self.renderer else { return }
                renderer.foldTarget = Settings.shared.simulationFold
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            view.isPaused = true
        }

        private func loadStill() {
            guard ScreenCaptureSource.hasPermission, let renderer, let screen = AppController.builtInScreen() else { return }
            let displayID = AppController.displayID(of: screen)
            Task { @MainActor in
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                    let ownApps = content.applications.filter { $0.processID == getpid() }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
                    config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let loader = MTKTextureLoader(device: renderer.device)
                    let texture = try await loader.newTexture(cgImage: image, options: [.SRGB: false])
                    renderer.accept(texture: texture)
                } catch {
                    NSLog("LidGlass: preview still failed: \(error)")
                }
            }
        }
    }
}

struct SettingsView: View {
    let controller: AppController
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                PreviewView(controller: controller)
                    .frame(width: 320, height: 200)
                    .background(Color.black.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Slider(value: $settings.simulationFold, in: 0...1) {
                    Text("Fold")
                }
                Toggle("Fold the screen with the slider", isOn: $settings.isSimulating)
                Text(sensorStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 320)

            Form {
                Section("Material") {
                    Picker("Effect", selection: $settings.effect) {
                        ForEach(GlassEffect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    slider("Frost", value: $settings.frost, range: 0...1)
                    slider("Perspective", value: $settings.perspective, range: 0...1)
                    slider("Edge softness", value: $settings.edgeSoftness, range: 0.5...16, unit: "px")
                    slider("Corner radius", value: $settings.cornerRadius, range: 0...120, unit: "px")
                }
                Section("Feel") {
                    slider("Responsiveness", value: $settings.responsiveness, range: 0.05...1)
                    slider("Hinge sensitivity", value: $settings.hingeSensitivity, range: 0.4...3)
                    slider("Minimum movement", value: $settings.minimumMovement, range: 0...6, unit: "°")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            slider("Start angle", value: $settings.startAngle, range: 30...160, unit: "°")
                            Button("Use current") { controller.useCurrentAngleAsStart() }
                                .disabled(!controller.sensorIsAvailable)
                        }
                        Text("The glass starts folding as the lid closes past this angle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Power") {
                    Picker("Stationary frame rate", selection: $settings.stationaryFrameRate) {
                        ForEach([15, 30, 60, 90, 120], id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                }
                Section("App") {
                    Toggle("Effect enabled", isOn: $settings.isEnabled)
                    Toggle("Show lid angle in menu bar", isOn: $settings.showsAngleInMenuBar)
                    Toggle("Open at login", isOn: $settings.opensAtLogin)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
        }
        .padding(18)
        .onDisappear { settings.isSimulating = false }
    }

    private var sensorStatus: String {
        guard controller.sensorIsAvailable else {
            return "No lid angle sensor found. Use the scrubber to see the effect."
        }
        return String(format: "Lid angle sensor: %.0f°", controller.currentAngle)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "") -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(unit.isEmpty ? String(format: "%.2f", value.wrappedValue) : String(format: "%.0f%@", value.wrappedValue, unit))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// Builds the settings window on open and drops it on close, so the preview and its
/// screenshot only exist while someone is looking at them.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "LidGlass"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}
