import Foundation
import LidGlassCore

var failures = 0

@MainActor func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "pass" : "FAIL")  \(name)")
    if !condition { failures += 1 }
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

let closed = FoldModel.closedAngle
// Travel runs from 108 (resting 110 minus a 2 degree deadband) down to the closed angle.
let halfway = (108 + closed) / 2

check("resting angle is unfolded",
      FoldModel.target(angle: 110, restingAngle: 110, sensitivity: 1, deadband: 2) == 0)
check("wobble inside the deadband stays unfolded",
      FoldModel.target(angle: 108.5, restingAngle: 110, sensitivity: 1, deadband: 2) == 0)
check("opening past rest stays unfolded",
      FoldModel.target(angle: 135, restingAngle: 110, sensitivity: 1, deadband: 2) == 0)
check("nearly shut is fully folded",
      FoldModel.target(angle: closed, restingAngle: 110, sensitivity: 1, deadband: 2) == 1)
check("fold is linear in angle",
      near(FoldModel.target(angle: halfway, restingAngle: 110, sensitivity: 1, deadband: 2), 0.5))
check("sensitivity scales travel per degree",
      FoldModel.target(angle: halfway, restingAngle: 110, sensitivity: 2, deadband: 2) == 1)

check("full responsiveness tracks exactly",
      FoldModel.smoothed(current: 0.2, target: 0.9, responsiveness: 1, deltaTime: 1.0 / 120) == 0.9)
check("no elapsed time holds position",
      FoldModel.smoothed(current: 0.2, target: 0.9, responsiveness: 0.5, deltaTime: 0) == 0.2)
check("one sensor sample moves by the responsiveness",
      near(FoldModel.smoothed(current: 0, target: 1, responsiveness: 0.25, deltaTime: 1 / FoldModel.sensorSampleRate), 0.25))

var fine = 0.0
for _ in 0..<12 { fine = FoldModel.smoothed(current: fine, target: 1, responsiveness: 0.3, deltaTime: 1.0 / 120) }
let coarse = FoldModel.smoothed(current: 0, target: 1, responsiveness: 0.3, deltaTime: 0.1)
check("step size does not change where smoothing lands", near(fine, coarse))

exit(failures == 0 ? 0 : 1)
