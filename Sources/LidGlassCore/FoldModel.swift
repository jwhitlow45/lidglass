import Foundation

/// Pure mapping from a lid-angle reading to the fold the renderer draws.
public enum FoldModel {
    /// How often the lid-angle sensor is read.
    public static let sensorSampleRate = 120.0

    /// Fold is zero until the lid has closed `deadband` degrees past the resting angle,
    /// then reaches one as the lid approaches shut. The sensor wobbles by a degree at rest,
    /// and without the deadband that wobble alone would fold the glass. Sensitivity
    /// multiplies travel per degree, so a higher value folds further for the same movement.
    public static func target(angle: Double, restingAngle: Double, sensitivity: Double, deadband: Double) -> Double {
        let start = restingAngle - deadband
        let travel = max(start - closedAngle, 1)
        let moved = (start - angle) * sensitivity
        return min(max(moved / travel, 0), 1)
    }

    /// Frame-rate independent exponential smoothing. Responsiveness 1 tracks the hand
    /// exactly, lower values trail it.
    public static func smoothed(current: Double, target: Double, responsiveness: Double, deltaTime: Double) -> Double {
        guard responsiveness < 1 else { return target }
        let perSample = 1 - pow(1 - responsiveness, deltaTime * sensorSampleRate)
        return current + (target - current) * min(max(perSample, 0), 1)
    }

    /// The lid is never read as fully shut: the display sleeps first.
    public static let closedAngle = 5.0
    /// How far the pane tips away at full fold.
    public static let maxTilt = 78.0 * .pi / 180.0
}
