import AppKit
import Carbon.HIToolbox
import Combine
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
        private var foldSubscription: AnyCancellable?

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
            // Follows the value as it changes rather than on a timer: while a slider is being
            // dragged, the main thread runs only the drag, and ordinary timers wait for release.
            foldSubscription = Settings.shared.$simulationFold.sink { [weak renderer] fold in
                renderer?.foldTarget = fold
            }
        }

        func stop() {
            foldSubscription = nil
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
                HStack {
                    Text("Fold")
                    FocusSlider(value: $settings.simulationFold, range: 0...1, step: 0.01)
                }
                Toggle("Fold the screen with the slider", isOn: $settings.isSimulating)
                Text(sensorStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 320)

            VStack(alignment: .leading, spacing: 14) {
                section("Material") {
                    Picker("Effect", selection: $settings.effect) {
                        ForEach(GlassEffect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Hinge edge", selection: $settings.hingeEdge) {
                        ForEach(HingeEdge.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    slider("Frost", value: $settings.frost, range: 0...1, step: 0.01)
                    slider("Perspective", value: $settings.perspective, range: 0...1, step: 0.01)
                    slider("Edge softness", value: $settings.edgeSoftness, range: 0.5...16, step: 0.5, unit: "px")
                    slider("Corner radius", value: $settings.cornerRadius, range: 0...120, step: 1, unit: "px")
                }
                section("Feel") {
                    slider("Responsiveness", value: $settings.responsiveness, range: 0.05...1, step: 0.01)
                    slider("Hinge sensitivity", value: $settings.hingeSensitivity, range: 0.4...3, step: 0.05)
                    slider("Minimum movement", value: $settings.minimumMovement, range: 0...6, step: 0.5, unit: "°")
                    HStack {
                        slider("Start angle", value: $settings.startAngle, range: 30...160, step: 1, unit: "°")
                        Button("Use current") { controller.useCurrentAngleAsStart() }
                            .disabled(!controller.sensorIsAvailable)
                    }
                    Text("The glass starts folding as the lid closes past this angle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                section("Power") {
                    Picker("Stationary frame rate", selection: $settings.stationaryFrameRate) {
                        ForEach([15, 30, 60, 90, 120], id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    Picker("Idle polling rate", selection: $settings.idlePollingRate) {
                        ForEach([5, 10, 20, 30, 60, 120], id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                    idleBatteryUse
                }
                section("App") {
                    switchRow("Effect enabled", isOn: $settings.isEnabled)
                    switchRow("Show lid angle in menu bar", isOn: $settings.showsAngleInMenuBar)
                    switchRow("Hide the system cursor while folded", isOn: $settings.hidesSystemCursor)
                    switchRow("Open at login", isOn: $settings.opensAtLogin)
                }
            }
            .frame(width: 420)
        }
        .padding(18)
        .onDisappear { settings.isSimulating = false }
    }

    /// How much reading a still lid costs, and the delay that buys back.
    private var idleBatteryUse: some View {
        let rate = settings.idlePollingRate
        let use = IdleBatteryUse(pollingRate: rate)
        return VStack(alignment: .leading, spacing: 2) {
            Label("Battery use while the lid is still: \(use.name)", systemImage: use.symbol)
                .foregroundStyle(use.style)
            Text("Reads the lid \(rate) times a second until it moves, so the glass can start up to \(1000 / rate) ms late. Higher rates react sooner and use more battery.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var sensorStatus: String {
        guard controller.sensorIsAvailable else {
            return "No lid angle sensor found. Use the scrubber to see the effect."
        }
        return String(format: "Lid angle sensor: %.0f°", controller.currentAngle)
    }

    /// Plain boxes rather than a grouped Form: a Form makes every row a focus stop of its
    /// own, and the arrow keys then move between rows instead of moving the row's slider.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        unit: String = "") -> some View {
        HStack {
            Text(title)
                .frame(width: 130, alignment: .leading)
            FocusSlider(value: value, range: range, step: step)
                .accessibilityLabel(title)
            Text(unit.isEmpty ? String(format: "%.2f", value.wrappedValue) : String(format: "%.0f%@", value.wrappedValue, unit))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// Measured on an M4 MacBook Pro, reading the sensor while the lid is still costs about
/// 0.1 percent of one core at 5 reads a second, 0.3 at 10, 0.6 at 20, 1.6 at 60, and 2.9
/// at 120.
private enum IdleBatteryUse {
    case veryLow, low, moderate, high

    init(pollingRate: Int) {
        switch pollingRate {
        case ..<15: self = .veryLow
        case ..<45: self = .low
        case ..<90: self = .moderate
        default: self = .high
        }
    }

    var name: String {
        switch self {
        case .veryLow: "Very low"
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }

    /// The battery drains in the icon as the cost goes up.
    var symbol: String {
        switch self {
        case .veryLow: "battery.100percent"
        case .low: "battery.75percent"
        case .moderate: "battery.50percent"
        case .high: "battery.25percent"
        }
    }

    var style: Color {
        switch self {
        case .veryLow, .low: .green
        case .moderate: .orange
        case .high: .red
        }
    }
}

/// A slider that takes keyboard focus when clicked, so the arrow keys move it straight
/// away. SwiftUI's own slider only takes focus through Tab.
private struct FocusSlider: NSViewRepresentable {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// How far one arrow key press moves the slider. Shift moves ten steps.
    let step: Double

    func makeCoordinator() -> Coordinator { Coordinator(value: value) }

    func makeNSView(context: Context) -> ArrowKeySlider {
        let slider = ArrowKeySlider(value: value.wrappedValue, minValue: range.lowerBound, maxValue: range.upperBound,
                                    target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.step = step
        return slider
    }

    func updateNSView(_ slider: ArrowKeySlider, context: Context) {
        context.coordinator.value = value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.step = step
        if slider.doubleValue != value.wrappedValue { slider.doubleValue = value.wrappedValue }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

private final class ArrowKeySlider: NSSlider {
    var step = 0.01

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let direction: Double
        switch event.specialKey {
        case .rightArrow?, .upArrow?: direction = 1
        case .leftArrow?, .downArrow?: direction = -1
        default:
            super.keyDown(with: event)
            return
        }
        let distance = step * (event.modifierFlags.contains(.shift) ? 10 : 1)
        doubleValue = min(max(doubleValue + direction * distance, minValue), maxValue)
        sendAction(action, to: target)
    }
}

/// Builds the settings window on open and drops it on close, so the preview and its
/// screenshot only exist while someone is looking at them.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var eventMonitor: Any?
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
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            self.window = window
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.stopSimulation(on: event) ?? event
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// While the slider folds the screen, the glass covers this window and hides the
    /// controls that would stop it. Escape stops it, and so does any click while the glass
    /// is showing. The click only stops the fold, rather than also landing on whatever
    /// control is hidden under the glass. Returns nil for an event it used up.
    private func stopSimulation(on event: NSEvent) -> NSEvent? {
        let settings = Settings.shared
        guard settings.isSimulating else { return event }
        let isEscape = event.type == .keyDown && event.keyCode == UInt16(kVK_Escape)
        let isClickOnGlass = event.type != .keyDown && controller.isShowingGlass
        guard isEscape || isClickOnGlass else { return event }
        settings.isSimulating = false
        return nil
    }

    /// Switching to another window or app stops the fold too.
    func windowDidResignKey(_ notification: Notification) {
        Settings.shared.isSimulating = false
    }

    func windowWillClose(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        window?.contentViewController = nil
        window = nil
    }
}
