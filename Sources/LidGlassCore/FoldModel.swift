import Foundation

/// Pure mapping from a lid-angle reading to the fold the renderer draws.
public enum FoldModel {
    /// Fold is zero until the lid closes past the start angle, and reaches one as the lid
    /// approaches shut. Sensitivity multiplies travel per degree, so a higher value folds
    /// further for the same movement.
    ///
    /// The sensor wobbles by a degree at rest, so starting the glass takes `wobbleGuard`
    /// degrees past the start angle. Once started, the fold is measured from the start
    /// angle itself and only stops when the lid opens back past it. That hysteresis is
    /// what lets the start angle sit exactly where the lid rests without the wobble
    /// folding the glass on its own.
    public static func target(angle: Double, startAngle: Double, sensitivity: Double,
                              wobbleGuard: Double, hasStarted: Bool) -> Double {
        let threshold = hasStarted ? startAngle : startAngle - wobbleGuard
        guard angle < threshold else { return 0 }
        let travel = max(startAngle - closedAngle, 1)
        let moved = (startAngle - angle) * sensitivity
        return min(max(moved / travel, 0), 1)
    }

    /// A critically damped spring, stepped by the time since the last frame.
    ///
    /// The sensor reports whole degrees, so the fold arrives as a staircase. Stepping a
    /// spring on every drawn frame, rather than on every sensor sample, rides through the
    /// steps and keeps the pane moving between them.
    public static func step(fold: Double, velocity: Double, target: Double,
                            responsiveness: Double, deltaTime: Double) -> (fold: Double, velocity: Double) {
        guard deltaTime > 0 else { return (fold, velocity) }
        let stiffness = minStiffness + responsiveness * (maxStiffness - minStiffness)
        // Several small steps keep a long frame from overshooting.
        let steps = max(Int((deltaTime / 0.004).rounded(.up)), 1)
        let dt = deltaTime / Double(steps)
        var fold = fold
        var velocity = velocity
        for _ in 0..<steps {
            let acceleration = stiffness * stiffness * (target - fold) - 2 * stiffness * velocity
            velocity += acceleration * dt
            fold += velocity * dt
        }
        if abs(target - fold) < restingTolerance && abs(velocity) < restingTolerance {
            return (target, 0)
        }
        return (min(max(fold, 0), 1), velocity)
    }

    /// Spring stiffness in radians per second, from the loosest responsiveness to the
    /// tightest: trailing the lid by about a sixth of a second down to about a frame.
    static let minStiffness = 6.0
    static let maxStiffness = 60.0
    /// Below this the fold is treated as settled, and the frame rate may drop.
    public static let restingTolerance = 0.0008

    /// The lid is never read as fully shut: the display sleeps first.
    public static let closedAngle = 5.0
    /// How far the pane tips away at full fold.
    public static let maxTilt = 78.0 * .pi / 180.0
}
