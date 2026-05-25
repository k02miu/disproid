import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// 指定した CGDirectDisplayID の画面を ScreenCaptureKit で取り込み、
/// フレーム(CVImageBuffer)をコールバックする。
///
/// 注意: 実行には macOS の「画面収録」許可(TCC)が必要。初回はシステムダイアログが出る。
@available(macOS 13.0, *)
final class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput {

    private let targetDisplayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    private let sampleQueue = DispatchQueue(label: "io.disproid.capture")
    private var stream: SCStream?

    /// フレーム到着コールバック（sampleQueue 上で呼ばれる）。
    var onFrame: ((CVImageBuffer, CMTime) -> Void)?

    init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) {
        self.targetDisplayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            throw NSError(domain: "ScreenCapturer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "対象ディスプレイ(\(targetDisplayID))が見つからない"])
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // フレームが complete か確認
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              let first = (attachments as? [[SCStreamFrameInfo: Any]])?.first,
              let statusRaw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(imageBuffer, pts)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("[capture] ストリーム停止: \(error)\n".utf8))
    }
}
