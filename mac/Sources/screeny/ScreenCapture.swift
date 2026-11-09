import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Delivers frames from one display. ScreenCaptureKit sends nothing while the screen
/// is static, so the last frame is resent briefly: hardware decoders can hold a frame
/// back until the next one arrives, which would otherwise leave the tablet out of date.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private static let repeatInterval = DispatchTimeInterval.milliseconds(100)
    private static let maxRepeats = 10

    private let queue = DispatchQueue(label: "screeny.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var lastBuffer: CVPixelBuffer?
    private var repeats = 0

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let display = try await findDisplay(displayID)

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.showsCursor = true
        configuration.queueDepth = 5

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        startRepeatTimer()
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        try? await stream?.stopCapture()
        stream = nil
    }

    /// A new virtual display takes a moment to show up in ScreenCaptureKit.
    private func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == id }) {
                return display
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DisplayError(description: "display \(id) never appeared in ScreenCaptureKit")
    }

    private func startRepeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.repeatInterval, repeating: Self.repeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.lastBuffer, self.repeats < Self.maxRepeats else { return }
            self.repeats += 1
            self.onFrame?(buffer)
        }
        timer.resume()
        self.timer = timer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastBuffer = buffer
        repeats = 0
        onFrame?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Capture stopped: \(error)")
    }
}
