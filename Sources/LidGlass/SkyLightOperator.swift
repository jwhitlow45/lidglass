import AppKit

/// Resolves the private WindowServer calls that put a window above the lock screen.
///
/// Adapted from Lakr233/SkyLightWindow (MIT license, github.com/Lakr233/SkyLightWindow),
/// trimmed to the calls LidGlass uses. SLS functions are undocumented SkyLight framework
/// SPI: resolved at runtime with dlsym, so a missing symbol degrades to "no overlay" rather
/// than a crash, and a future macOS that removes them costs nothing worse than that.
enum SkyLightSpaceLevel: Int32 {
    case screenLock = 300
}

final class SkyLightOperator {
    static let shared = SkyLightOperator()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let mainConnectionID: MainConnectionID?
    private let spaceCreate: SpaceCreate?
    private let spaceSetAbsoluteLevel: SpaceSetAbsoluteLevel?
    private let showSpaces: ShowSpaces?
    private let addWindowsAndRemoveFromSpaces: SpaceAddWindowsAndRemoveFromSpaces?

    /// The space is created lazily, the first time a window actually needs it: resolving
    /// the symbols has no visible effect, but creating and showing the space does, so
    /// merely checking `isAvailable` (for the settings window's status line, say) must not
    /// trigger it.
    private var connection: Int32?
    private var space: Int32?

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let mainConnectionIDSymbol = dlsym(handle, "SLSMainConnectionID"),
              let spaceCreateSymbol = dlsym(handle, "SLSSpaceCreate"),
              let spaceSetAbsoluteLevelSymbol = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSpacesSymbol = dlsym(handle, "SLSShowSpaces"),
              let addWindowsSymbol = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            mainConnectionID = nil
            spaceCreate = nil
            spaceSetAbsoluteLevel = nil
            showSpaces = nil
            addWindowsAndRemoveFromSpaces = nil
            return
        }
        mainConnectionID = unsafeBitCast(mainConnectionIDSymbol, to: MainConnectionID.self)
        spaceCreate = unsafeBitCast(spaceCreateSymbol, to: SpaceCreate.self)
        spaceSetAbsoluteLevel = unsafeBitCast(spaceSetAbsoluteLevelSymbol, to: SpaceSetAbsoluteLevel.self)
        showSpaces = unsafeBitCast(showSpacesSymbol, to: ShowSpaces.self)
        addWindowsAndRemoveFromSpaces = unsafeBitCast(addWindowsSymbol, to: SpaceAddWindowsAndRemoveFromSpaces.self)
    }

    var isAvailable: Bool { mainConnectionID != nil }

    /// Puts `window` in the screen-lock space, creating that space on first use.
    func delegate(_ window: NSWindow) {
        ensureSpace()
        guard let connection, let space, let addWindowsAndRemoveFromSpaces else { return }
        _ = addWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
    }

    private func ensureSpace() {
        guard connection == nil,
              let mainConnectionID, let spaceCreate, let spaceSetAbsoluteLevel, let showSpaces else { return }
        let cid = mainConnectionID()
        let sid = spaceCreate(cid, 1, 0)
        _ = spaceSetAbsoluteLevel(cid, sid, SkyLightSpaceLevel.screenLock.rawValue)
        _ = showSpaces(cid, [sid] as CFArray)
        connection = cid
        space = sid
    }
}
