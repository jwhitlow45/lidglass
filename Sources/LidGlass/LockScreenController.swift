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
    /// Bumped on every reveal and conceal, so a delayed step of an older one (the fallback
    /// timer covering a frame that never presents, say) does nothing once superseded.
    private var revealChange = 0
    /// The last target `update(target:)` received, reused by `selfTick`.
    private var lastTarget: Double = 0
    /// Runs only while shown: `AppController` only calls `update(target:)` when its own,
    /// separately-timed spring is still moving or the lid itself moves, and this spring can
    /// still be settling after that one goes quiet, or after the lid stops moving entirely.
    /// Left to that alone, a still-open, still-decaying pane could stay on screen (and stay
    /// unchecked against the real session) far longer than intended.
    private var selfTickTimer: Timer?
    /// True once a reload has finished, applied its texture, and been shown at least once
    /// for the reveal in progress. Reset whenever the fold returns to flat, even if the
    /// window was never actually shown (a reload still pending when the lid opened back up,
    /// say): without that, a load started before an unobserved unlock could still land and
    /// mark itself fresh after the unlock, and a later reveal in the same lock session would
    /// trust it without ever reloading.
    private var hasFreshWallpaper = false
    /// Bumped on every reload attempt, on teardown, and whenever the fold returns to flat,
    /// so a completion can tell whether a newer attempt (or a cancellation) has since
    /// superseded it. Two loads can be in flight briefly (a fast one started after a slow
    /// one), and without this the slow one finishing last could overwrite the fast one's
    /// already-applied, already-shown result with an older picture.
    private var wallpaperGeneration = 0
    private var isReloadingWallpaper = false
    /// Left at zero until a load fails, then holds when that failure happened: a failure
    /// that keeps failing must not retry at whatever rate the lid happens to be ticking at,
    /// up to 120 times a second.
    private var lastWallpaperFailureTime: TimeInterval = 0
    private static let wallpaperRetryDelay: TimeInterval = 2.0

    init() {
        if !sky.isAvailable {
            NSLog("LidGlass: cannot show on the lock screen, the private system call it needs is unavailable")
        }
    }

    deinit {
        selfTickTimer?.invalidate()
        // deinit can run on whatever thread happened to drop the last reference. AppKit
        // calls need the main thread, and `tearDown()` is expected to have already run (see
        // AppController's handling of the setting that owns this controller's lifetime), so
        // this is only a fallback for a path that skipped it.
        let window = self.window
        DispatchQueue.main.async { window?.orderOut(nil) }
    }

    /// Called on every controller tick, alongside the normal overlay, with the same raw
    /// target `AppController` just computed from the lid angle. This steps its own spring
    /// toward that target rather than mirroring the normal overlay's already-smoothed fold:
    /// the normal overlay's window sits behind the real lock screen while locked, and macOS
    /// throttles drawing for a window nothing can see, so borrowing its motion looked
    /// noticeably more stuttery here than on the desktop.
    func update(target: Double) {
        lastTarget = target
        apply(target: target)
    }

    /// Runs both from `update(target:)` and, while shown, from `selfTickTimer`, using
    /// whatever target was last known either way.
    private func apply(target: Double) {
        guard sky.isAvailable, settings.showsOnLockScreen, settings.isEnabled else {
            tearDown()
            return
        }
        // Checked whenever something might need to show, or a cached renderer needs to be
        // confirmed still valid, not on every idle tick: a flat lid with nothing built has
        // nothing to show or invalidate regardless of whether it is locked.
        guard target > FoldModel.restingTolerance || isShowingWindow || renderer != nil else { return }
        // The lock/unlock notifications macOS posts are not guaranteed delivery (Apple's
        // own documentation says so), so this checks the real session state itself rather
        // than trusting a notification history. This also covers launching while already
        // locked, waking from sleep, and unlocking while a cached renderer sits hidden
        // between two folds in the same session, none of which post a fresh notification
        // to react to. Checking whenever a renderer is cached, not only while visible, is
        // what keeps that cached renderer's wallpaper from surviving past the unlock that
        // should have invalidated it.
        guard LockScreenController.isScreenLocked() else {
            tearDown()
            return
        }
        buildIfNeeded()
        guard let renderer, let screen = AppController.builtInScreen(), let view else { return }
        renderer.foldTarget = target
        if view.isPaused { renderer.stepFold() }
        let isFolded = renderer.fold > FoldModel.restingTolerance || target > FoldModel.restingTolerance
        // Reacts to the raw target, not the spring: the spring can take a real fraction of
        // a second to visually catch up (stepFold's deltaTime is wall-clock and capped),
        // so isFolded can still read true for a moment after the lid has already opened
        // back up. A pending or cached wallpaper for the fold that is going away must not
        // survive to the next one, and that has to happen the moment intent changes, not
        // once the cosmetic animation finishes settling. This also covers a reload still in
        // flight, not only a currently-shown window: without it, a load that was still
        // pending when the lid opened back up could land and mark itself fresh after an
        // unobserved unlock and wallpaper change, and the next fold would trust it without
        // ever reloading.
        if target <= FoldModel.restingTolerance {
            invalidateWallpaper()
        }
        if isFolded {
            // A cached renderer can sit idle across an unlock the controller never directly
            // observes, if the lid does not move again until the next lock (see
            // reloadWallpaper). Reloading right as it is about to actually be seen, rather
            // than trying to catch the unlock itself, means what is shown is always current
            // regardless of what happened while nothing was watching. The window only
            // becomes visible once that load has actually finished and been applied
            // (`revealIfStillAppropriate`, called from the load's completion), not the
            // moment the load merely starts: showing it first would mean showing whatever
            // the cached renderer already had, stale, for however long the load takes, or
            // forever if it fails.
            if hasFreshWallpaper {
                setVisible(true)
            } else if target > FoldModel.restingTolerance {
                // Only the raw target may start a fresh load. Without this guard, the
                // invalidation above (target already flat, spring still easing down) would
                // otherwise read as "no wallpaper, still folded" and kick off a reload
                // nothing needs: the window should just fade out on what it already has.
                reloadWallpaper(screen: screen, into: renderer)
            }
        } else {
            setVisible(false)
        }
        view.preferredFramesPerSecond = renderer.isAnimating ? 120 : settings.stationaryFrameRate
    }

    /// Re-checks everything `apply` would have, since a reload finishing is an async event
    /// that can land after conditions have moved on: the setting could have been turned
    /// off, the screen could have been unlocked, or the lid could be back to flat.
    private func revealIfStillAppropriate() {
        guard hasFreshWallpaper, sky.isAvailable, settings.showsOnLockScreen, settings.isEnabled,
              LockScreenController.isScreenLocked(), let renderer else { return }
        guard renderer.fold > FoldModel.restingTolerance || lastTarget > FoldModel.restingTolerance else { return }
        setVisible(true)
    }

    /// Keeps checking after `update(target:)` stops being called, so a pane that is still
    /// decaying toward flat still gets concealed, and the real session state still gets
    /// rechecked, once the normal overlay (which drives when `update` is called) has
    /// already gone quiet.
    private func startSelfTicking() {
        guard selfTickTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.apply(target: self.lastTarget)
        }
        RunLoop.main.add(timer, forMode: .common)
        selfTickTimer = timer
    }

    private func stopSelfTicking() {
        selfTickTimer?.invalidate()
        selfTickTimer = nil
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
        // Not loaded here: a session check happens each time this is about to actually
        // show, whether that is the first fold of a lock or a later one reusing a cached
        // renderer, and the wallpaper is reloaded at that same moment, see
        // reloadWallpaper.
    }

    /// The wallpaper stands in for the real lock screen, which cannot be captured. It is not
    /// enough to reload it once per lock and trust the cache the rest of that lock session:
    /// a session this controller never directly observes (the lid never moving between an
    /// unlock and the next lock, so no callback of any kind arrives in between) can end with
    /// a cached renderer from the previous lock still in place, showing its now-stale
    /// picture. Reloading right before every reveal, not only the first one, means what
    /// shows is always the current picture regardless of what happened while unwatched.
    private func reloadWallpaper(screen: NSScreen, into renderer: GlassRenderer) {
        guard let device, !isReloadingWallpaper else { return }
        guard lastWallpaperFailureTime == 0
            || Date().timeIntervalSinceReferenceDate - lastWallpaperFailureTime > LockScreenController.wallpaperRetryDelay
        else { return }
        isReloadingWallpaper = true
        wallpaperGeneration += 1
        let generation = wallpaperGeneration
        let pixelSize = screen.frame.size.applying(CGAffineTransform(scaleX: screen.backingScaleFactor, y: screen.backingScaleFactor))
        let width = max(Int(pixelSize.width.rounded()), 1)
        let height = max(Int(pixelSize.height.rounded()), 1)
        // Captured weakly: a pending load must not be what keeps this controller alive after
        // the setting that owns it has already let it go (turned off, then straight back on,
        // say, which would otherwise leave two controllers alive at once, this one a zombie
        // still able to act on the settings and session state it shares with the real one).
        Task { [weak self] in
            let image = await LockScreenController.loadWallpaperImage(screen, width, height)
            let texture: MTLTexture?
            if let image {
                texture = try? await MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false])
            } else {
                texture = nil
            }
            // Upgraded to a strong local reference here, once: if the controller is already
            // gone, there is nothing left to apply this to.
            guard let self else { return }
            await MainActor.run {
                // A newer reload, or a cancellation (the fold returning to flat before this
                // one finished), has since changed the generation. Whichever order two loads
                // finish in, an older one must never overwrite a newer one's already-applied
                // result, or revive a reveal that was already called off. Checked before
                // touching any other state: an obsolete completion must not even clear the
                // busy flag, since a still-current attempt may be the one holding it.
                guard generation == self.wallpaperGeneration else { return }
                self.isReloadingWallpaper = false
                guard let texture else {
                    NSLog("LidGlass: could not load the desktop picture for the lock screen effect")
                    self.lastWallpaperFailureTime = Date().timeIntervalSinceReferenceDate
                    return
                }
                renderer.accept(texture: texture)
                self.hasFreshWallpaper = true
                self.revealIfStillAppropriate()
            }
        }
    }

    /// Loads and fills the current wallpaper for `screen` to exactly `width` x `height`. A
    /// `static var` closure, like `isScreenLocked`, so a test can control timing and
    /// success or failure without touching the real filesystem.
    static var loadWallpaperImage: (_ screen: NSScreen, _ width: Int, _ height: Int) async -> CGImage? = { screen, width, height in
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return LockScreenController.fillImage(at: url, width: width, height: height)
    }

    /// Scales the image at `url` up or down just enough to cover `width` x `height`, and
    /// crops whatever overhangs, centered, the way macOS's own "Fill Screen" desktop
    /// picture option does. The shader's corner radius and edge softness are measured in
    /// the source texture's own pixels, matching the normal overlay's captured frame, which
    /// is always exactly the screen's pixel size. The wallpaper file on disk is not: it can
    /// be any resolution, and any aspect ratio, down to a portrait photo set as the picture
    /// for a landscape screen. Loaded as is, that stretches the whole image, corners
    /// included, into an oval.
    private static func fillImage(at url: URL, width: Int, height: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Applies EXIF orientation (a portrait photo stored sideways with rotation metadata,
        // say) before any of the math below runs, rather than trusting the file's raw,
        // possibly-rotated pixel grid: unapplied, both the crop and the final image would
        // come out rotated the same way the raw file is.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let imageWidth = CGFloat(image.width), imageHeight = CGFloat(image.height)
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let scale = max(CGFloat(width) / imageWidth, CGFloat(height) / imageHeight)
        let scaledWidth = imageWidth * scale, scaledHeight = imageHeight * scale
        // Matches the color space the renderer's view actually presents in: a mismatched
        // color space here would still decode correctly, but every color would come out
        // shifted, since nothing downstream converts between them.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: ScreenCaptureSource.colorSpace) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let origin = CGPoint(x: (CGFloat(width) - scaledWidth) / 2, y: (CGFloat(height) - scaledHeight) / 2)
        context.draw(image, in: CGRect(origin: origin, size: CGSize(width: scaledWidth, height: scaledHeight)))
        return context.makeImage()
    }

    /// The window only enters and leaves the screen while fully transparent, the same
    /// reason the normal overlay's window does: appearing or disappearing while visible
    /// flashes the whole screen, and a window just brought back still shows its previous
    /// content (the last reveal's now-superseded wallpaper, here) until it draws again.
    private func setVisible(_ visible: Bool) {
        guard visible != isShowingWindow, let window, let view else { return }
        isShowingWindow = visible
        revealChange += 1
        let change = revealChange
        view.isPaused = !visible
        if visible {
            window.alphaValue = 0
            window.orderFrontRegardless()
            let turnVisible = { [weak self, weak window] in
                guard self?.revealChange == change else { return }
                window?.alphaValue = 1
            }
            renderer?.onNextPresent = turnVisible
            // Covers a frame that never reports being shown.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: turnVisible)
            startSelfTicking()
        } else {
            window.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                guard self?.revealChange == change else { return }
                window?.orderOut(nil)
            }
            stopSelfTicking()
            invalidateWallpaper()
        }
    }

    /// Marks any cached wallpaper, and any reload still in flight, as no longer good enough
    /// to show without being validated again: the next reveal, even a later one in the same
    /// lock session, or a load that was already on its way when this ran, must not act as
    /// though it is still current.
    private func invalidateWallpaper() {
        hasFreshWallpaper = false
        wallpaperGeneration += 1
    }

    /// Explicit teardown, not left to `deinit`: called both when this controller is about
    /// to be discarded (the setting turning off) and when it needs to rebuild in place
    /// (sleep, a display change, an unlock). Always runs on the main thread, since callers
    /// only ever reach it from `AppController`'s own main-queue-driven code.
    func tearDown() {
        stopSelfTicking()
        isReloadingWallpaper = false
        invalidateWallpaper()
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
