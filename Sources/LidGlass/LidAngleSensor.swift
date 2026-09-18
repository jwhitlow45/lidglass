import Foundation
import IOKit.hid
import LidGlassCore

/// Reads the MacBook's continuous lid-angle sensor.
///
/// The sensor shows up as an Apple HID device named "las" on usage page 0x20 (sensors),
/// usage 0x8A. Feature report 1 answers with three bytes: the report id followed by the
/// angle in whole degrees as a little-endian 16-bit value. Machines without the sensor
/// simply have no matching device, which is how `isAvailable` stays honest.
final class LidAngleSensor {
    private static let angleReportID: CFIndex = 1

    private let queue = DispatchQueue(label: "lidglass.sensor", qos: .userInteractive)
    /// Releasing the manager closes every device it opened, so it lives as long as we do.
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?

    /// Delivered on the main queue at the sample rate while the sensor is open.
    var onAngle: ((Double) -> Void)?

    var isAvailable: Bool { device != nil }

    init() {
        device = LidAngleSensor.openDevice(using: manager)
    }

    deinit {
        timer?.cancel()
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    func start() {
        guard device != nil, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / FoldModel.sensorSampleRate, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let angle = self.readAngle() else { return }
            DispatchQueue.main.async { self.onAngle?(angle) }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Blocking single read, used by the command line angle dump and by calibration.
    func readAngle() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, LidAngleSensor.angleReportID, &report, &length)
        guard result == kIOReturnSuccess, length >= 3, report[0] == UInt8(LidAngleSensor.angleReportID) else { return nil }
        return Double(Int(report[1]) | Int(report[2]) << 8)
    }

    private static func openDevice(using manager: IOHIDManager) -> IOHIDDevice? {
        let matching: [String: Any] = [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }
        return device
    }
}
