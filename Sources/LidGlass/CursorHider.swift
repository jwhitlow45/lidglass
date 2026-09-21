import CoreGraphics
import Darwin

/// Hides the real cursor while the glass is up, so the only cursor on screen is the
/// captured one, folded with the rest of the screen.
///
/// macOS ignores cursor hiding from apps that are not frontmost, and LidGlass never is.
/// The private WindowServer connection property "SetsCursorInBackground" lifts that. Its
/// functions are looked up at run time, so if a future macOS drops them the app still
/// launches and the real cursor simply stays visible. WindowServer shows the cursor again
/// if the app quits or crashes while it is hidden.
final class CursorHider {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private let canHide: Bool
    private var isHidden = false

    init() {
        // RTLD_DEFAULT: search every image already loaded, where CoreGraphics provides these.
        let everyImage = UnsafeMutableRawPointer(bitPattern: -2)
        guard let mainConnectionSymbol = dlsym(everyImage, "CGSMainConnectionID"),
              let setPropertySymbol = dlsym(everyImage, "CGSSetConnectionProperty") else {
            canHide = false
            return
        }
        let mainConnection = unsafeBitCast(mainConnectionSymbol, to: MainConnectionID.self)
        let setProperty = unsafeBitCast(setPropertySymbol, to: SetConnectionProperty.self)
        let connection = mainConnection()
        canHide = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }

    func hide() {
        guard canHide, !isHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        isHidden = true
    }

    func show() {
        guard isHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isHidden = false
    }
}
