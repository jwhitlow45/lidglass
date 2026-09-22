import AppKit
import CoreGraphics
import LidGlassCore
import Metal
import MetalKit

/// Optionally folds the desktop wallpaper over the lock screen while it is locked. Off by
/// default: see `Settings.showsOnLockScreen`, which carries the warning about what this
/// does. macOS blocks capturing the real lock screen, so unlike the normal overlay this
/// folds a still of the desktop picture rather than the screen underneath it, and it never
/// takes clicks or key presses, so it can never be in the way of actually unlocking.
final class LockScreenController {
    private let settings = Settings.shared
    private let sky = SkyLightOperator.shared

    private var device: MTLDevice?
    private var renderer: GlassRenderer?
    private var window: LockScreenWindow?
    private var view: OverlayView?
    private var isShowingWindow = false

    init() {
        if !sky.isAvailable {
            NSLog("LidGlass: cannot show on the lock screen, the private system call it needs is unavailable")
        }
    }

    deinit {
        window?.orderOut(nil)
    }

    /// Called on every controller tick, alongside the normal overlay, with the same raw
    /// target `AppController` just computed from the lid angle. This steps its own spring
    /// toward that target rather than mirroring the normal overlay's already-smoothed fold:
    /// the normal overlay's window sits behind the real lock screen while locked, and macOS
    /// throttles drawing for a window nothing can see, so borrowing its motion looked
    /// noticeably more stuttery here than on the desktop.
    func update(target: Double) {
        guard sky.isAvailable, settings.showsOnLockScreen, settings.isEnabled else {
            tearDown()
            return
        }
        // An idle, flat lid has nothing to show regardless of whether it is locked, so it
        // is left alone here rather than torn down: tearing down would mean reloading the
        // wallpaper and rebuilding the renderer on every settle, in case the same lock
        // session folds again.
        guard target > FoldModel.restingTolerance || isShowingWindow else { return }
        // The lock/unlock notifications macOS posts are not guaranteed delivery (Apple's
        // own documentation says so), so this checks the real session state itself rather
        // than trusting a notification history. This also covers launching while already
        // locked and waking from sleep, neither of which posts a fresh notification to
        // react to.
        guard LockScreenController.isScreenLocked() else {
            tearDown()
            return
        }
        buildIfNeeded()
        guard let renderer, let view else { return }
        renderer.foldTarget = target
        if view.isPaused { renderer.stepFold() }
        let isFolded = renderer.fold > FoldModel.restingTolerance || target > FoldModel.restingTolerance
        setVisible(isFolded)
        view.preferredFramesPerSecond = renderer.isAnimating ? 120 : settings.stationaryFrameRate
    }

    /// The built-in display changing (an external monitor connected or disconnected while
    /// locked, say) needs a fresh window sized for whatever screen is current. The next
    /// tick rebuilds it if still relevant.
    func handleScreenChange() {
        tearDown()
    }

    /// Closing the lid all the way sleeps the Mac. Nothing runs while asleep, and the next
    /// tick after waking rebuilds from scratch if still relevant, so this is only to release
    /// the GPU resources for the duration, not for correctness.
    func handleSleep() {
        tearDown()
    }

    /// Read directly from the WindowServer session rather than trusted from a notification.
    /// A `static var` closure rather than a plain function so it can be substituted in a
    /// test, which cannot make the real screen lock to order.
    static var isScreenLocked: () -> Bool = {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func buildIfNeeded() {
        guard renderer == nil, let screen = AppController.builtInScreen(),
              let device = MTLCreateSystemDefaultDevice(), let renderer = GlassRenderer(device: device) else { return }
        renderer.settings = settings

        let window = LockScreenWindow(screen: screen)
        let view = OverlayView(device: device, renderer: renderer)
        view.colorspace = CGColorSpace(name: ScreenCaptureSource.colorSpace)
        view.frame = window.contentLayoutRect
        window.contentView = view
        sky.delegate(window)

        self.device = device
        self.renderer = renderer
        self.window = window
        self.view = view
        loadWallpaper(screen: screen, device: device, into: renderer)
    }

    /// The wallpaper stands in for the real lock screen, which cannot be captured: it is
    /// reloaded once per lock, in case it changed since the last one.
    private func loadWallpaper(screen: NSScreen, device: MTLDevice, into renderer: GlassRenderer) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        Task {
            guard let texture = try? await MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false]) else {
                NSLog("LidGlass: could not load the desktop picture for the lock screen effect")
                return
            }
            await MainActor.run { renderer.accept(texture: texture) }
        }
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isShowingWindow, let window, let view else { return }
        isShowingWindow = visible
        view.isPaused = !visible
        if visible {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    private func tearDown() {
        guard renderer != nil || isShowingWindow else { return }
        window?.orderOut(nil)
        view?.isPaused = true
        window = nil
        view = nil
        renderer = nil
        device = nil
        isShowingWindow = false
    }
}
