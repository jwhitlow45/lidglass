import AppKit
import LidGlassCore
import Combine
import Metal
import MetalKit

/// Wires the sensor to the capture stream and the overlay, and decides when each of them
/// is allowed to cost anything.
final class AppController: ObservableObject {
    static let settleDelay = 0.3

    private let settings = Settings.shared
    private let sensor = LidAngleSensor()
    private var capture: ScreenCaptureSource?
    private var renderer: GlassRenderer?
    private var window: OverlayWindow?
    private var view: OverlayView?
    /// The capture draws the cursor into the glass, so the real one would be a second copy.
    private let cursor = CursorHider()

    /// The latest lid reading, observed by the settings window.
    @Published private(set) var angle: Double = 0
    /// The angle movement is measured from. It only follows the lid in steps of the
    /// minimum movement, which keeps the sensor's wobble at rest from counting as moving.
    /// The rendered angle above follows every sample, so the glass never moves in steps.
    private var movementAnchor: Double = 0
    private var lastMovementTime = 0.0
    /// Mirrors what the sensor was last told, so a tick only reaches it on a change.
    private var sensorIsTracking = false
    /// Whether the glass should be on screen. The window trails this by a frame or two in
    /// each direction, see reveal and conceal.
    private var isGlassUp = false
    /// Bumped by every reveal and conceal, so a delayed step of an older one does nothing.
    private var glassChange = 0
    private var fallbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Reported to the menu bar.
    var onAngleChange: ((Double, Bool) -> Void)?

    var sensorIsAvailable: Bool { sensor.isAvailable }

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
        // A still lid sends no readings, so a setting that changes where the glass should be
        // ticks the controller itself. A published setting announces itself before it is
        // stored, and tick() reads the stored values, so these ticks wait for the next turn of
        // the main queue. The main queue, unlike a run loop timer, keeps running while a
        // slider is dragged.
        let changesToTheGlass: [AnyPublisher<Void, Never>] = [
            settings.$isEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$isSimulating.map { _ in () }.eraseToAnyPublisher(),
            settings.$simulationFold.map { _ in () }.eraseToAnyPublisher(),
            settings.$startAngle.map { _ in () }.eraseToAnyPublisher(),
            settings.$hingeSensitivity.map { _ in () }.eraseToAnyPublisher(),
            settings.$minimumMovement.map { _ in () }.eraseToAnyPublisher(),
            settings.$hidesSystemCursor.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changesToTheGlass)
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
    var isShowingGlass: Bool { isGlassUp }

    func useCurrentAngleAsStart() {
        if let angle = sensor.readAngle() { settings.startAngle = angle }
    }

    // MARK: - Sampling

    private func handle(angle newAngle: Double) {
        if newAngle != angle { angle = newAngle }
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
            if !isGlassUp { reveal(window, drawnBy: renderer) }
            // Hiding is global, but the glass covers only the built-in display. A pointer on
            // another display has no captured copy, so it stays visible there.
            let isPointerOnGlass = window.frame.contains(NSEvent.mouseLocation)
            if settings.hidesSystemCursor && isPointerOnGlass { cursor.hide() } else { cursor.show() }
        } else {
            view.isPaused = true
            if isGlassUp { conceal(window) }
            cursor.show()
        }
    }

    /// The glass window only enters and leaves the screen while fully transparent. A
    /// full-screen window appearing or disappearing while visible flashes the whole screen,
    /// and a window just brought back still shows the last frame of the previous fold until
    /// it draws again. So it turns visible once its first new frame is on screen, and turns
    /// transparent a few frames before it is removed.
    private func reveal(_ window: OverlayWindow, drawnBy renderer: GlassRenderer?) {
        isGlassUp = true
        glassChange += 1
        let change = glassChange
        window.alphaValue = 0
        window.orderFrontRegardless()
        let turnVisible = { [weak self, weak window] in
            guard self?.glassChange == change else { return }
            window?.alphaValue = 1
        }
        renderer?.onNextPresent = turnVisible
        // Covers a frame that never reports being shown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: turnVisible)
    }

    private func conceal(_ window: OverlayWindow) {
        isGlassUp = false
        glassChange += 1
        let change = glassChange
        window.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
            guard self?.glassChange == change else { return }
            window?.orderOut(nil)
        }
    }

    private func shutDownEffect() {
        isGlassUp = false
        glassChange += 1
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
        view.colorspace = CGColorSpace(name: ScreenCaptureSource.colorSpace)
        view.frame = window.contentLayoutRect
        window.contentView = view

        let displayID = AppController.displayID(of: screen)
        let pixelSize = screen.frame.size.applying(CGAffineTransform(scaleX: screen.backingScaleFactor, y: screen.backingScaleFactor))
        let capture = ScreenCaptureSource(displayID: displayID, pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
        capture.onFrame = { [weak renderer] pixelBuffer in renderer?.accept(pixelBuffer: pixelBuffer) }
        // Stopping the capture from the macOS sharing menu means the person wants it off.
        // Restarting it on the next reading would overrule them, so the effect turns off
        // until they turn it back on from the menu bar.
        capture.onUserStopped = { [weak self] in self?.settings.isEnabled = false }

        self.renderer = renderer
        self.window = window
        self.view = view
        self.capture = capture
    }

    /// The effect belongs to the display that moves with the lid. With the lid shut and an
    /// external display in use there is none, and no other display may fold in its place.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { CGDisplayIsBuiltin(displayID(of: $0)) != 0 }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
