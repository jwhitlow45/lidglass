import Foundation
import IOKit.hid

/// Reads the MacBook's continuous lid-angle sensor.
///
/// The sensor shows up as an Apple HID device named "las" on usage page 0x20 (sensors),
/// usage 0x8A. Feature report 1 answers with three bytes: the report id followed by the
/// angle in whole degrees as a little-endian 16-bit value. Machines without the sensor
/// simply have no matching device, which is how `isAvailable` stays honest.
///
/// The sensor has to be polled. It does send the angle unasked, but only once a second
/// whether or not the lid is moving, and it ignores requests to send faster. Polling runs
/// at two speeds. While tracking, every reading goes to the main queue, where each one
/// steps the glass. While idle, the sensor is read at the slower idle rate and only a
/// changed reading goes to the main queue, so a still lid never wakes the main thread.
final class LidAngleSensor {
    static let trackingRate = 120
    private static let angleReportID: CFIndex = 1

    private let queue = DispatchQueue(label: "lidglass.sensor", qos: .userInteractive)
    /// Releasing the manager closes every device it opened, so it lives as long as we do.
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?

    // Owned by the queue.
    private var timer: DispatchSourceTimer?
    private var idleRate = 20
    private var isTracking = false
    private var lastAngle: Double?

    /// Delivered on the main queue: every reading while tracking, changes only while idle.
    var onAngle: ((Double) -> Void)?

    var isAvailable: Bool { device != nil }

    init() {
        device = LidAngleSensor.openDevice(using: manager)
    }

    deinit {
        timer?.cancel()
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    func start(idleRate: Int) {
        queue.async {
            self.idleRate = idleRate
            self.restartTimer()
        }
    }

    func setIdleRate(_ rate: Int) {
        queue.async {
            guard rate != self.idleRate else { return }
            self.idleRate = rate
            if !self.isTracking { self.restartTimer() }
        }
    }

    func setTracking(_ tracking: Bool) {
        queue.async {
            guard tracking != self.isTracking else { return }
            self.isTracking = tracking
            self.restartTimer()
        }
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

    private func restartTimer() {
        guard device != nil else { return }
        timer?.cancel()
        let rate = isTracking ? LidAngleSensor.trackingRate : idleRate
        // Idle reads may drift by a tenth of their interval, which lets macOS batch them
        // with other wakeups. Tracking reads stay on time so the glass moves evenly.
        let leeway = isTracking ? 1 : max(1, 100 / rate)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(rate), leeway: .milliseconds(leeway))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard let angle = readAngle(), isTracking || angle != lastAngle else { return }
        lastAngle = angle
        DispatchQueue.main.async { [weak self] in self?.onAngle?(angle) }
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
