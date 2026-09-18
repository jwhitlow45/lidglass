import AppKit
import Foundation

// Sensor dump mode: useful for checking that this Mac reports a lid angle at all,
// without granting the app any permissions.
if CommandLine.arguments.contains("--angle") {
    let sensor = LidAngleSensor()
    guard sensor.isAvailable else {
        FileHandle.standardError.write("no lid angle sensor found\n".data(using: .utf8)!)
        exit(1)
    }
    while true {
        if let angle = sensor.readAngle() {
            print(String(format: "%.0f", angle))
            fflush(stdout)
        }
        usleep(50_000)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render") {
    exit(runRenderCommand(Array(CommandLine.arguments.dropFirst(index + 1))))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
