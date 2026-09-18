import AppKit
import LidGlassCore
import Combine
import Metal
import MetalKit

/// Wires the sensor to the capture stream and the overlay, and decides when each of them
/// is allowed to cost anything.
final class AppController {
    static let settleDelay = 0.3

    private let settings = Settings.shared
    private let sensor = LidAngleSensor()
    private var capture: ScreenCaptureSource?
    private var renderer: GlassRenderer?
    private var window: OverlayWindow?
    private var view: OverlayView?

    private var angle: Double = 0
    private var fold: Double = 0
    private var lastSampleTime = CACurrentMediaTime()
    private var lastMovementTime = 0.0
    private var fallbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Reported to the menu bar.
    var onAngleChange: ((Double, Bool) -> Void)?

    var sensorIsAvailable: Bool { sensor.isAvailable }
    var currentAngle: Double { angle }

    func start() {
        buildOverlay()
        angle = sensor.readAngle() ?? settings.restingAngle
        calibrateOnFirstLaunch()
        sensor.onAngle = { [weak self] angle in self?.handle(angle: angle) }
        sensor.start()
        if !sensor.isAvailable { startFallbackTicks() }

        settings.$isEnabled
            .sink { [weak self] enabled in if !enabled { self?.shutDownEffect() } }
            .store(in: &cancellables)
        settings.$isSimulating
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
        settings.$simulationFold
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildOverlay() }
        // Closing the lid all the way sleeps the Mac. The last frame is of a screen that
        // will not be there on wake, so it goes, and the reopening folds in fresh frames.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.shutDownEffect() }
    }

    /// A resting angle above the angle the lid actually sits at would hold the glass
    /// partly folded, so the first launch takes the current angle as the resting one.
    private func calibrateOnFirstLaunch() {
        let key = "hasCalibratedRestingAngle"
        guard !UserDefaults.standard.bool(forKey: key), let angle = sensor.readAngle() else { return }
        settings.restingAngle = angle
        UserDefaults.standard.set(true, forKey: key)
    }

    /// The fold the renderer is drawing right now, for the settings preview.
    var currentFold: Double { fold }

    func calibrateRestingAngle() {
        if let angle = sensor.readAngle() { settings.restingAngle = angle }
    }

    // MARK: - Sampling

    private func handle(angle newAngle: Double) {
        if abs(newAngle - angle) >= settings.minimumMovement {
            lastMovementTime = CACurrentMediaTime()
            angle = newAngle
        }
        onAngleChange?(newAngle, sensor.isAvailable)
        tick()
    }

    private func startFallbackTicks() {
        // No sensor: the scrubber in the settings window is the only source of movement.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let deltaTime = min(now - lastSampleTime, 0.1)
        lastSampleTime = now

        let target = settings.simulatedFold
            ?? FoldModel.target(angle: angle, restingAngle: settings.restingAngle,
                                sensitivity: settings.hingeSensitivity, deadband: settings.minimumMovement)
        fold = FoldModel.smoothed(current: fold, target: target, responsiveness: settings.responsiveness, deltaTime: deltaTime)
        if abs(fold - target) < 0.0005 { fold = target }
        renderer?.fold = fold

        let isMoving = settings.simulatedFold != nil || now - lastMovementTime < AppController.settleDelay
        let isFolded = fold > 0.001 || target > 0.001
        apply(isMoving: isMoving, isFolded: isFolded && settings.isEnabled)
    }

    // MARK: - Power

    private func apply(isMoving: Bool, isFolded: Bool) {
        guard let capture, let view, let window else { return }
        let frameRate = isMoving ? 120 : settings.stationaryFrameRate

        if isFolded || (isMoving && settings.isEnabled) {
            if capture.isRunning {
                capture.setFrameRate(frameRate)
            } else {
                capture.start(frameRate: frameRate)
            }
        } else {
            // Also cancels a start still in flight.
            capture.stop()
            renderer?.dropFrames()
        }

        let shouldShow = isFolded && renderer?.hasFrame == true
        if shouldShow {
            view.preferredFramesPerSecond = frameRate
            view.isPaused = false
            if !window.isVisible { window.orderFrontRegardless() }
        } else {
            view.isPaused = true
            if window.isVisible { window.orderOut(nil) }
        }
    }

    private func shutDownEffect() {
        capture?.stop()
        renderer?.dropFrames()
        view?.isPaused = true
        window?.orderOut(nil)
    }

    // MARK: - Overlay

    private func rebuildOverlay() {
        shutDownEffect()
        window = nil
        view = nil
        capture = nil
        renderer = nil
        buildOverlay()
    }

    private func buildOverlay() {
        guard let device = MTLCreateSystemDefaultDevice(), let screen = AppController.builtInScreen() else { return }
        guard let renderer = GlassRenderer(device: device) else { return }
        renderer.settings = settings
        renderer.onFirstFrame = { [weak self] in self?.tick() }

        let window = OverlayWindow(screen: screen)
        let view = OverlayView(device: device, renderer: renderer)
        view.frame = window.contentLayoutRect
        window.contentView = view

        let displayID = AppController.displayID(of: screen)
        let pixelSize = screen.frame.size.applying(CGAffineTransform(scaleX: screen.backingScaleFactor, y: screen.backingScaleFactor))
        let capture = ScreenCaptureSource(displayID: displayID, pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
        capture.onFrame = { [weak renderer] pixelBuffer in renderer?.accept(pixelBuffer: pixelBuffer) }

        self.renderer = renderer
        self.window = window
        self.view = view
        self.capture = capture
    }

    /// The effect belongs to the display that moves with the lid.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { CGDisplayIsBuiltin(displayID(of: $0)) != 0 } ?? NSScreen.main
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
