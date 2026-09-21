import Foundation
import LidGlassCore

var failures = 0

@MainActor func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "pass" : "FAIL")  \(name)")
    if !condition { failures += 1 }
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

let closed = FoldModel.closedAngle
// Travel runs from the 110 degree start angle down to the closed angle.
let halfway = (110 + closed) / 2

func target(_ angle: Double, sensitivity: Double = 1, hasStarted: Bool = false) -> Double {
    FoldModel.target(angle: angle, startAngle: 110, sensitivity: sensitivity,
                     wobbleGuard: 2, hasStarted: hasStarted)
}

check("the start angle is unfolded", target(110) == 0)
check("wobble under the start angle does not start the glass", target(108.5) == 0)
check("opening past the start angle stays unfolded", target(135) == 0)
check("closing past the wobble guard starts the glass", target(107) > 0)
check("nearly shut is fully folded", target(closed) == 1)
check("fold is linear in angle", near(target(halfway, hasStarted: true), 0.5))
check("sensitivity scales travel per degree", target(halfway, sensitivity: 2, hasStarted: true) == 1)
check("once started the fold follows the lid back up to the start angle",
      near(target(109, hasStarted: true), (110 - 109) / (110 - closed)))
check("opening back past the start angle stops the glass", target(110, hasStarted: true) == 0)

// The spring runs at a frame's pace and lands on the target without overshooting it.
func settle(from fold: Double, to target: Double, responsiveness: Double, seconds: Double)
    -> (fold: Double, velocity: Double, peak: Double) {
    var fold = fold
    var velocity = 0.0
    var peak = fold
    for _ in 0..<Int(seconds * 120) {
        (fold, velocity) = FoldModel.step(fold: fold, velocity: velocity, target: target,
                                          responsiveness: responsiveness, deltaTime: 1.0 / 120)
        peak = max(peak, fold)
    }
    return (fold, velocity, peak)
}

check("no elapsed time holds position",
      FoldModel.step(fold: 0.2, velocity: 0, target: 0.9, responsiveness: 0.5, deltaTime: 0).fold == 0.2)
check("the fold moves toward the target",
      FoldModel.step(fold: 0, velocity: 0, target: 1, responsiveness: 0.5, deltaTime: 1.0 / 120).fold > 0)
check("a tight spring is on the lid within a quarter second",
      abs(settle(from: 0, to: 1, responsiveness: 1, seconds: 0.25).fold - 1) < 0.001)
check("a loose spring trails the lid",
      settle(from: 0, to: 1, responsiveness: 0.05, seconds: 0.1).fold < 0.6)
check("the glass does not overshoot",
      settle(from: 0, to: 0.5, responsiveness: 1, seconds: 1).peak <= 0.5 + 1e-9)
check("the fold comes to rest on the target",
      settle(from: 0, to: 0.7, responsiveness: 0.45, seconds: 2).velocity == 0)
check("the fold stays within its range",
      settle(from: 0, to: 1, responsiveness: 1, seconds: 1).peak <= 1)

// A long frame must land in the same place as the frames it stands in for.
let long = FoldModel.step(fold: 0, velocity: 0, target: 1, responsiveness: 0.45, deltaTime: 0.05)
var short = (fold: 0.0, velocity: 0.0)
for _ in 0..<6 {
    short = FoldModel.step(fold: short.fold, velocity: short.velocity, target: 1,
                           responsiveness: 0.45, deltaTime: 0.05 / 6)
}
check("a long frame lands close to several short ones", abs(long.fold - short.fold) < 0.02)

// Release versions decide whether an update installs, so a wrong comparison either skips
// updates or installs an older build.
func version(_ text: String) -> ReleaseVersion? { ReleaseVersion(text) }
check("a tag reads as its version", version("v1.2.3")?.parts == [1, 2, 3])
check("a newer patch is newer", version("0.0.2")! > version("0.0.1")!)
check("versions compare by number, not text", version("0.0.10")! > version("0.0.9")!)
check("a newer minor beats any patch", version("0.2.0")! > version("0.1.99")!)
check("missing trailing parts are zero", version("1.2")! == version("1.2.0")!)
check("the same version is not newer", !(version("v0.0.1")! > version("0.0.1")!))
check("an older version is not newer", !(version("0.0.9")! > version("0.1.0")!))
check("a pre-release suffix is not a version", version("1.2.3-beta") == nil)
check("an empty part is not a version", version("1..3") == nil && version("") == nil)
check("a negative part is not a version", version("1.-2.3") == nil)

exit(failures == 0 ? 0 : 1)
