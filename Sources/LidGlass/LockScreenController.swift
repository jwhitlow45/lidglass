import AppKit
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

    private var isLocked = false
    private var isShowingWindow = false
    private var lockToken: NSObjectProtocol?
    private var unlockToken: NSObjectProtocol?

    init() {
        if !sky.isAvailable {
            NSLog("LidGlass: cannot show on the lock screen, the private system call it needs is unavailable")
        }
        let center = DistributedNotificationCenter.default()
        lockToken = center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = true
            self?.buildIfNeeded()
        }
        unlockToken = center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = false
            self?.tearDown()
        }
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        if let lockToken { center.removeObserver(lockToken) }
        if let unlockToken { center.removeObserver(unlockToken) }
        window?.orderOut(nil)
    }

    /// Called on every controller tick, alongside the normal overlay. `fold` is the real
    /// overlay's already-smoothed fold: this mirrors it exactly rather than running its own
    /// spring, so the two never drift apart. `isFolded` decides whether anything should show
    /// right now, independent of whether the screen happens to be locked.
    func update(fold: Double, isFolded: Bool) {
        guard sky.isAvailable, settings.showsOnLockScreen, settings.isEnabled, isLocked,
              let renderer, window != nil, view != nil else {
            if isShowingWindow { setVisible(false) }
            return
        }
        renderer.foldTarget = fold
        renderer.settleFold()
        setVisible(isFolded)
    }

    /// The built-in display changing (an external monitor connected or disconnected while
    /// locked, say) needs a fresh window sized for whatever screen is current.
    func handleScreenChange() {
        guard renderer != nil else { return }
        tearDown()
        if isLocked { buildIfNeeded() }
    }

    /// Closing the lid all the way sleeps the Mac, same as the normal overlay's own sleep
    /// handling: the window would otherwise show a wallpaper frame from before sleep until
    /// the next lock notification arrives, which is not guaranteed to be prompt on wake.
    func handleSleep() {
        tearDown()
    }

    private func buildIfNeeded() {
        guard renderer == nil, sky.isAvailable, settings.showsOnLockScreen, settings.isEnabled,
              let screen = AppController.builtInScreen(), let device = MTLCreateSystemDefaultDevice(),
              let renderer = GlassRenderer(device: device) else { return }
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
        window?.orderOut(nil)
        view?.isPaused = true
        window = nil
        view = nil
        renderer = nil
        device = nil
        isShowingWindow = false
    }
}
