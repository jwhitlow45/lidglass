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

/// Per-effect material constants. A mapped type keeps every effect answerable: adding a
/// case to GlassEffect without a material here is a compile error.
struct Material {
    var frostTop: Float
    var frostBottom: Float
    var grainScale: Float
    var grainStrength: Float
    var scatter: Float
    var sheen: Float
    var chroma: Float
    var tint: (r: Float, g: Float, b: Float)
    var tintStrength: Float
    var paneAlpha: Float
    /// Scatter reach in pixels at full frost.
    var blurRadius: Float
}

let materials: [GlassEffect: Material] = [
    .frosted: Material(frostTop: 1.0, frostBottom: 0.2, grainScale: 1.5, grainStrength: 0.05,
                       scatter: 0.5, sheen: 0.05, chroma: 0, tint: (0.93, 0.96, 1.0), tintStrength: 0.2,
                       paneAlpha: 1.0, blurRadius: 44),
    .etched: Material(frostTop: 0.9, frostBottom: 0.15, grainScale: 1.0, grainStrength: 0.12,
                      scatter: 1.0, sheen: 0.09, chroma: 0, tint: (0.96, 0.97, 0.99), tintStrength: 0.15,
                      paneAlpha: 1.0, blurRadius: 30),
    .ghost: Material(frostTop: 1.0, frostBottom: 0.45, grainScale: 2.0, grainStrength: 0.03,
                     scatter: 0.4, sheen: 0.04, chroma: 0, tint: (1.0, 1.0, 1.0), tintStrength: 0.3,
                     paneAlpha: 0.45, blurRadius: 56),
    .smoke: Material(frostTop: 1.0, frostBottom: 0.4, grainScale: 1.5, grainStrength: 0.06,
                     scatter: 0.6, sheen: 0.03, chroma: 0, tint: (0.16, 0.17, 0.2), tintStrength: 0.4,
                     paneAlpha: 0.92, blurRadius: 48),
    .prism: Material(frostTop: 0.8, frostBottom: 0.15, grainScale: 1.5, grainStrength: 0.04,
                     scatter: 0.5, sheen: 0.08, chroma: 6, tint: (0.95, 0.95, 1.0), tintStrength: 0.1,
                     paneAlpha: 1.0, blurRadius: 32),
    .clear: Material(frostTop: 0.35, frostBottom: 0.05, grainScale: 2.0, grainStrength: 0.02,
                     scatter: 0.3, sheen: 0.12, chroma: 0, tint: (0.97, 0.99, 1.0), tintStrength: 0.08,
                     paneAlpha: 1.0, blurRadius: 16),
]

/// User-facing settings, mirrored into UserDefaults so they survive a relaunch.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var isEnabled: Bool { didSet { store(isEnabled, "isEnabled") } }
    @Published var effect: GlassEffect { didSet { store(effect.rawValue, "effect") } }
    @Published var frost: Double { didSet { store(frost, "frost") } }
    @Published var perspective: Double { didSet { store(perspective, "perspective") } }
    @Published var edgeSoftness: Double { didSet { store(edgeSoftness, "edgeSoftness") } }
    @Published var cornerRadius: Double { didSet { store(cornerRadius, "cornerRadius") } }
    @Published var responsiveness: Double { didSet { store(responsiveness, "responsiveness") } }
    @Published var hingeSensitivity: Double { didSet { store(hingeSensitivity, "hingeSensitivity") } }
    @Published var minimumMovement: Double { didSet { store(minimumMovement, "minimumMovement") } }
    @Published var startAngle: Double { didSet { store(startAngle, "startAngle") } }
    @Published var stationaryFrameRate: Int { didSet { store(stationaryFrameRate, "stationaryFrameRate") } }
    @Published var showsAngleInMenuBar: Bool { didSet { store(showsAngleInMenuBar, "showsAngleInMenuBar") } }

    /// Scrubber state from the settings window. While simulating, the scrubber drives the
    /// fold instead of the sensor. Neither value is worth keeping across launches.
    @Published var isSimulating = false
    @Published var simulationFold = 0.5

    /// Mirrors the login item registration so the toggle can drive it directly.
    @Published var opensAtLogin: Bool { didSet { applyLoginItem() } }

    var simulatedFold: Double? { isSimulating ? simulationFold : nil }

    var material: Material { materials[effect] ?? materials[.frosted]! }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "isEnabled": true,
            "effect": GlassEffect.frosted.rawValue,
            "frost": 0.8,
            "perspective": 0.55,
            "edgeSoftness": 2.0,
            "cornerRadius": 48.0,
            "responsiveness": 0.45,
            "hingeSensitivity": 1.0,
            "minimumMovement": 2.0,
            "startAngle": 110.0,
            "stationaryFrameRate": 30,
            "showsAngleInMenuBar": false,
        ])
        isEnabled = d.bool(forKey: "isEnabled")
        effect = GlassEffect(rawValue: d.string(forKey: "effect") ?? "") ?? .frosted
        frost = d.double(forKey: "frost")
        perspective = d.double(forKey: "perspective")
        edgeSoftness = d.double(forKey: "edgeSoftness")
        cornerRadius = d.double(forKey: "cornerRadius")
        responsiveness = d.double(forKey: "responsiveness")
        hingeSensitivity = d.double(forKey: "hingeSensitivity")
        minimumMovement = d.double(forKey: "minimumMovement")
        startAngle = d.double(forKey: "startAngle")
        stationaryFrameRate = d.integer(forKey: "stationaryFrameRate")
        showsAngleInMenuBar = d.bool(forKey: "showsAngleInMenuBar")
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLoginItem() {
        do {
            if opensAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LidGlass: login item change failed: \(error)")
        }
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
