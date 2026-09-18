import AppKit
import MetalKit

/// A click-through, borderless window that sits above everything on the built-in display.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        displaysWhenScreenProfileChanges = true
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Metal view that never draws on its own schedule: the controller asks for frames while
/// the fold is live and lets it idle otherwise.
final class OverlayView: MTKView {
    init(device: MTLDevice, renderer: GlassRenderer) {
        super.init(frame: .zero, device: device)
        delegate = renderer
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        layer?.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        autoResizeDrawable = true
        isPaused = true
        enableSetNeedsDisplay = false
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }
}
