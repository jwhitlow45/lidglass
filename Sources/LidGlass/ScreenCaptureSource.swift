import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import QuartzCore

/// Streams one display's frames. The stream only runs while the lid is moving, so the
/// idle cost of the app is a 120 Hz sensor read and nothing else.
final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let outputQueue = DispatchQueue(label: "lidglass.capture", qos: .userInteractive)

    private var stream: SCStream?
    private var currentFrameRate = 0
    private var isStarting = false
    /// Lets a stop that lands while a start is still in flight win.
    private var wantsRunning = false
    /// Without permission every start fails, and the controller asks at the sensor rate.
    private var lastFailure = -Double.infinity
    private static let retryDelay = 2.0

    /// Frames arrive in this color space, and the glass is drawn in it too, so the glass
    /// matches the screen exactly when it takes over. A MacBook display carries its own
    /// calibrated profile rather than a named space, and Display P3 is the named space
    /// closest to it.
    static let colorSpace = CGColorSpace.displayP3

    /// Called on the capture queue for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue when the person stops the capture from macOS.
    var onUserStopped: (() -> Void)?

    var isRunning: Bool { stream != nil }

    init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Call on the main thread, as with every other method here.
    func start(frameRate: Int) {
        wantsRunning = true
        // Each ScreenCaptureKit call without permission makes macOS post another prompt,
        // so the only request is the one made at launch.
        guard ScreenCaptureSource.hasPermission,
              stream == nil, !isStarting,
              CACurrentMediaTime() - lastFailure > ScreenCaptureSource.retryDelay else { return }
        isStarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStarting = false }
            do {
                let filter = try await self.makeFilter()
                let stream = SCStream(filter: filter, configuration: self.configuration(frameRate: frameRate), delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
                try await stream.startCapture()
                guard self.wantsRunning else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.currentFrameRate = frameRate
            } catch {
                self.lastFailure = CACurrentMediaTime()
                NSLog("LidGlass: capture start failed: \(error)")
            }
        }
    }

    func setFrameRate(_ frameRate: Int) {
        guard let stream, frameRate != currentFrameRate else { return }
        currentFrameRate = frameRate
        Task {
            try? await stream.updateConfiguration(configuration(frameRate: frameRate))
        }
    }

    func stop() {
        wantsRunning = false
        guard let stream else { return }
        self.stream = nil
        currentFrameRate = 0
        Task { try? await stream.stopCapture() }
    }

    private func configuration(frameRate: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = ScreenCaptureSource.colorSpace
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = false
        return config
    }

    /// Our own overlay shows the captured frames, so capturing it back would feed the
    /// image into itself. Excluding the whole app also keeps the settings window out.
    /// Off-screen windows count: the overlay is hidden when the stream starts, and an app
    /// with no on-screen windows is missing from the list and so escapes the exclusion.
    private func makeFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayGone
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID || $0.processID == getpid() }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    enum CaptureError: Error { case displayGone }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        guard isFrameComplete(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("LidGlass: capture stopped: \(error)")
        let wasStoppedByUser = (error as? SCStreamError)?.code == .userStopped
        DispatchQueue.main.async {
            if self.stream === stream { self.stream = nil }
            if wasStoppedByUser { self.onUserStopped?() }
        }
    }

    /// ScreenCaptureKit also delivers idle and blank frames. Only complete ones carry pixels.
    private func isFrameComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }
}
