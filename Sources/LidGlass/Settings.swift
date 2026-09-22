import Foundation
import Combine
import ServiceManagement

enum GlassEffect: String, CaseIterable, Identifiable {
    case frosted = "Frosted"
    case etched = "Etched"
    case ghost = "Ghost"
    case smoke = "Smoke"
    case prism = "Prism"
    case clear = "Clear"

    var id: String { rawValue }
}

/// The screen edge the glass folds on. A MacBook's own hinge is along the bottom.
enum HingeEdge: String, CaseIterable, Identifiable {
    case bottom = "Bottom"
    case top = "Top"

    var id: String { rawValue }
}

/// Per-effect material constants. A mapped type keeps every effect answerable: adding a
/// case to GlassEffect without a material here is a compile error.
struct Material {
    /// Frost at the free edge and at the hinge, as a share of the Frost setting.
    var frostTop: Float
    var frostBottom: Float
    /// Size of a grain cell, in captured pixels.
    var grainScale: Float
    var grainStrength: Float
    /// 0 for a smooth blur, 1 for sandblasted.
    var scatter: Float
    var sheen: Float
    /// Color split at the pane's edges at full frost, in captured pixels.
    var chroma: Float
    var tint: (r: Float, g: Float, b: Float)
    var tintStrength: Float
    var paneAlpha: Float
    /// Scatter reach in pixels at full frost.
    var blurRadius: Float
    /// Strength of the reflected band of light.
    var gloss: Float
}

let materials: [GlassEffect: Material] = [
    // A smooth, even blur.
    .frosted: Material(frostTop: 1.0, frostBottom: 0.3, grainScale: 1, grainStrength: 0,
                       scatter: 0, sheen: 0.05, chroma: 0, tint: (0.93, 0.96, 1.0), tintStrength: 0.2,
                       paneAlpha: 1.0, blurRadius: 56, gloss: 0),
    // Visible sandblasted grain over a lighter blur.
    .etched: Material(frostTop: 1.0, frostBottom: 0.25, grainScale: 2, grainStrength: 0.14,
                      scatter: 1.0, sheen: 0.08, chroma: 0, tint: (0.96, 0.97, 0.99), tintStrength: 0.18,
                      paneAlpha: 1.0, blurRadius: 22, gloss: 0),
    .ghost: Material(frostTop: 1.0, frostBottom: 0.45, grainScale: 1, grainStrength: 0.03,
                     scatter: 0.4, sheen: 0.04, chroma: 0, tint: (1.0, 1.0, 1.0), tintStrength: 0.3,
                     paneAlpha: 0.45, blurRadius: 56, gloss: 0),
    .smoke: Material(frostTop: 1.0, frostBottom: 0.4, grainScale: 1, grainStrength: 0.06,
                     scatter: 0.6, sheen: 0.03, chroma: 0, tint: (0.16, 0.17, 0.2), tintStrength: 0.4,
                     paneAlpha: 0.92, blurRadius: 48, gloss: 0),
    // Strong rainbow edges over a light blur.
    .prism: Material(frostTop: 0.8, frostBottom: 0.15, grainScale: 1.5, grainStrength: 0.02,
                     scatter: 0.3, sheen: 0.08, chroma: 36, tint: (0.95, 0.95, 1.0), tintStrength: 0.08,
                     paneAlpha: 1.0, blurRadius: 14, gloss: 0),
    // No frost: the fold and a glossy highlight.
    .clear: Material(frostTop: 0, frostBottom: 0, grainScale: 1, grainStrength: 0,
                     scatter: 0, sheen: 0.04, chroma: 0, tint: (1.0, 1.0, 1.0), tintStrength: 0,
                     paneAlpha: 1.0, blurRadius: 0, gloss: 0.6),
]

/// User-facing settings, mirrored into UserDefaults so they survive a relaunch.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var isEnabled: Bool { didSet { store(isEnabled, "isEnabled") } }
    @Published var effect: GlassEffect { didSet { store(effect.rawValue, "effect") } }
    @Published var hingeEdge: HingeEdge { didSet { store(hingeEdge.rawValue, "hingeEdge") } }
    /// How strongly the effect shows, from none (just the fold) to full. Stored under its
    /// first name, frost, so a saved value carries over.
    @Published var strength: Double { didSet { store(strength, "frost") } }
    @Published var perspective: Double { didSet { store(perspective, "perspective") } }
    @Published var edgeSoftness: Double { didSet { store(edgeSoftness, "edgeSoftness") } }
    @Published var cornerRadius: Double { didSet { store(cornerRadius, "cornerRadius") } }
    @Published var responsiveness: Double { didSet { store(responsiveness, "responsiveness") } }
    @Published var hingeSensitivity: Double { didSet { store(hingeSensitivity, "hingeSensitivity") } }
    @Published var minimumMovement: Double { didSet { store(minimumMovement, "minimumMovement") } }
    @Published var startAngle: Double { didSet { store(startAngle, "startAngle") } }
    @Published var stationaryFrameRate: Int { didSet { store(stationaryFrameRate, "stationaryFrameRate") } }
    @Published var idlePollingRate: Int { didSet { store(idlePollingRate, "idlePollingRate") } }
    @Published var showsAngleInMenuBar: Bool { didSet { store(showsAngleInMenuBar, "showsAngleInMenuBar") } }
    @Published var hidesSystemCursor: Bool { didSet { store(hidesSystemCursor, "hidesSystemCursor") } }
    @Published var updatesAutomatically: Bool { didSet { store(updatesAutomatically, "updatesAutomatically") } }
    /// Off by default: see the warning next to its toggle in Settings before turning it on.
    @Published var showsOnLockScreen: Bool { didSet { store(showsOnLockScreen, "showsOnLockScreen") } }

    /// Scrubber state from the settings window. While simulating, the scrubber drives the
    /// fold instead of the sensor. Neither value is worth keeping across launches.
    @Published var isSimulating = false
    @Published var simulationFold = 0.5

    /// Mirrors the login item registration so the toggle can drive it directly.
    @Published var opensAtLogin: Bool { didSet { if !isShowingLoginItemStatus { applyLoginItem() } } }

    var simulatedFold: Double? { isSimulating ? simulationFold : nil }

    var material: Material { materials[effect] ?? materials[.frosted]! }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "isEnabled": true,
            "effect": GlassEffect.frosted.rawValue,
            "hingeEdge": HingeEdge.bottom.rawValue,
            "frost": 0.8,
            "perspective": 0.55,
            "edgeSoftness": 2.0,
            "cornerRadius": 48.0,
            "responsiveness": 0.45,
            "hingeSensitivity": 1.0,
            "minimumMovement": 2.0,
            "startAngle": 110.0,
            "stationaryFrameRate": 30,
            "idlePollingRate": 20,
            "showsAngleInMenuBar": false,
            "hidesSystemCursor": true,
            "updatesAutomatically": true,
            "showsOnLockScreen": false,
        ])
        isEnabled = d.bool(forKey: "isEnabled")
        effect = GlassEffect(rawValue: d.string(forKey: "effect") ?? "") ?? .frosted
        hingeEdge = HingeEdge(rawValue: d.string(forKey: "hingeEdge") ?? "") ?? .bottom
        strength = d.double(forKey: "frost")
        perspective = d.double(forKey: "perspective")
        edgeSoftness = d.double(forKey: "edgeSoftness")
        cornerRadius = d.double(forKey: "cornerRadius")
        responsiveness = d.double(forKey: "responsiveness")
        hingeSensitivity = d.double(forKey: "hingeSensitivity")
        minimumMovement = d.double(forKey: "minimumMovement")
        startAngle = d.double(forKey: "startAngle")
        stationaryFrameRate = d.integer(forKey: "stationaryFrameRate")
        idlePollingRate = d.integer(forKey: "idlePollingRate")
        showsAngleInMenuBar = d.bool(forKey: "showsAngleInMenuBar")
        hidesSystemCursor = d.bool(forKey: "hidesSystemCursor")
        updatesAutomatically = d.bool(forKey: "updatesAutomatically")
        showsOnLockScreen = d.bool(forKey: "showsOnLockScreen")
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Set while the toggle is being corrected to the real status, so the correction does
    /// not register or unregister the login item again.
    private var isShowingLoginItemStatus = false

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if opensAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("LidGlass: login item change failed: \(error)")
        }
        // macOS can hold a new login item until the person approves it, so send them to
        // where they approve it.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refreshLoginItemStatus()
    }

    /// Shows whether LidGlass will actually open at login, which may differ from what was
    /// last asked for: registering can fail, and approval can change in System Settings.
    func refreshLoginItemStatus() {
        let isEnabled = SMAppService.mainApp.status == .enabled
        guard isEnabled != opensAtLogin else { return }
        isShowingLoginItemStatus = true
        opensAtLogin = isEnabled
        isShowingLoginItemStatus = false
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
