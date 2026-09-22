import AppKit

/// Sits above the lock screen, but never takes input: it must never be able to block
/// unlocking. `canBecomeVisibleWithoutLogin` is a real, if undocumented, NSWindow property
/// (declared in the public AppKit header) that lets a window draw at the login/lock screen.
final class LockScreenWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        canBecomeVisibleWithoutLogin = true
        level = .init(rawValue: Int(Int32.max - 2))
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        displaysWhenScreenProfileChanges = true
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
