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
    /// The capture draws the cursor into the glass, so the real one would be a second copy.
    private let cursor = CursorHider()

    private var angle: Double = 0
    /// The angle movement is measured from. It only follows the lid in steps of the
    /// minimum movement, which keeps the sensor's wobble at rest from counting as moving.
    /// The rendered angle above follows every sample, so the glass never moves in steps.
    private var movementAnchor: Double = 0
    private var lastMovementTime = 0.0
    /// Mirrors what the sensor was last told, so a tick only reaches it on a change.
    private var sensorIsTracking = false
    private var fallbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Reported to the menu bar.
    var onAngleChange: ((Double, Bool) -> Void)?

    var sensorIsAvailable: Bool { sensor.isAvailable }
    var currentAngle: Double { angle }

    func start() {
        buildOverlay()
        angle = sensor.readAngle() ?? settings.startAngle
        movementAnchor = angle
        calibrateOnFirstLaunch()
        sensor.onAngle = { [weak self] angle in self?.handle(angle: angle) }
        sensor.start(idleRate: settings.idlePollingRate)
        if !sensor.isAvailable { startFallbackTicks() }

        settings.$idlePollingRate
            .dropFirst()
            .sink { [weak self] rate in self?.sensor.setIdleRate(rate) }
            .store(in: &cancellables)

        settings.$isEnabled
            .sink { [weak self] enabled in if !enabled { self?.shutDownEffect() } }
            .store(in: &cancellables)
        // A published setting announces itself before it is stored, and tick() reads the
        // stored values, so these ticks wait for the next turn of the main queue. The main
        // queue, unlike a run loop timer, keeps running while a slider is dragged.
        Publishers.Merge3(settings.$isSimulating.map { _ in () },
                          settings.$simulationFold.map { _ in () },
                          settings.$hidesSystemCursor.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.tick() }
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

    /// A start angle above the angle the lid actually sits at would hold the glass partly
    /// folded, so the first launch starts the glass from where the lid is sitting.
    private func calibrateOnFirstLaunch() {
        let key = "hasCalibratedStartAngle"
        guard !UserDefaults.standard.bool(forKey: key), let angle = sensor.readAngle() else { return }
        settings.startAngle = angle
        UserDefaults.standard.set(true, forKey: key)
    }

    /// The fold the renderer is drawing right now, for the settings preview.
    var currentFold: Double { renderer?.fold ?? 0 }

    /// True while the glass covers the screen.
    var isShowingGlass: Bool { window?.isVisible == true }

    func useCurrentAngleAsStart() {
        if let angle = sensor.readAngle() { settings.startAngle = angle }
    }

    // MARK: - Sampling

    private func handle(angle newAngle: Double) {
        angle = newAngle
        if abs(newAngle - movementAnchor) >= settings.minimumMovement {
            lastMovementTime = CACurrentMediaTime()
            movementAnchor = newAngle
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
        guard let renderer else { return }
        let target = settings.simulatedFold
            ?? FoldModel.target(angle: angle, startAngle: settings.startAngle,
                                sensitivity: settings.hingeSensitivity, wobbleGuard: settings.minimumMovement,
                                hasStarted: renderer.foldTarget > 0)
        renderer.foldTarget = target
        // While the overlay is hidden nothing is drawing, so the spring is stepped here.
        if view?.isPaused != false { renderer.stepFold() }

        let isMoving = settings.simulatedFold != nil || CACurrentMediaTime() - lastMovementTime < AppController.settleDelay
        let isFolded = renderer.fold > FoldModel.restingTolerance || target > FoldModel.restingTolerance
        apply(isMoving: isMoving, isAnimating: renderer.isAnimating, isFolded: isFolded && settings.isEnabled)

        // Track the lid closely from the first movement until the glass is flat and still.
        let isTracking = settings.isEnabled && (isMoving || isFolded || renderer.isAnimating)
        if isTracking != sensorIsTracking {
            sensorIsTracking = isTracking
            sensor.setTracking(isTracking)
        }
    }

    // MARK: - Power

    private func apply(isMoving: Bool, isAnimating: Bool, isFolded: Bool) {
        guard let capture, let view, let window else { return }
        // A slow close reaches the minimum movement only every few tenths of a second, so
        // the frame rate follows the glass rather than the last sensor step.
        let frameRate = isMoving || isAnimating ? 120 : settings.stationaryFrameRate

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
            if settings.hidesSystemCursor { cursor.hide() } else { cursor.show() }
        } else {
            view.isPaused = true
            if window.isVisible { window.orderOut(nil) }
            cursor.show()
        }
    }

    private func shutDownEffect() {
        cursor.show()
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
