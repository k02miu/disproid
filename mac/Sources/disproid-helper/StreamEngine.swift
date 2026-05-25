import Foundation
import Combine
import CoreGraphics

/// 仮想ディスプレイ生成 → キャプチャ → エンコード → USB(adb) 送信、の一連を管理する。
/// SwiftUI から状態を監視できる ObservableObject。
final class StreamEngine: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case waitingForClient     // 起動済み・タブレット接続待ち
        case streaming            // タブレット接続中
        case error(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var statsText: String = ""
    @Published var width: Int = 1920
    @Published var height: Int = 1080
    /// ビットレート(Mbps)。稼働中の変更もエンコーダへ即反映する。
    @Published var bitrateMbps: Int = 20 {
        didSet { encoder?.setBitrate(bitrateMbps * 1_000_000) }
    }

    private let devicePort: UInt16 = 27184
    private let hostPort: UInt16 = 27184
    private let isH265 = false

    private var virtualDisplay: VirtualDisplay?
    private var server: FrameServer?
    private var encoder: VideoEncoder?
    private var capturer: ScreenCapturer?
    private var statTimer: DispatchSourceTimer?

    // 統計
    private var statCaptured = 0
    private var statEncoded = 0
    private var statBytes = 0

    var isRunning: Bool {
        if case .stopped = state { return false }
        if case .error = state { return false }
        return true
    }

    func start() {
        guard !isRunning else { return }
        setState(.starting)

        let w = width, h = height

        // 仮想ディスプレイ
        var opts = Options()
        opts.width = UInt32(w)
        opts.height = UInt32(h)
        opts.name = "Disproid Virtual Display"
        let vd = VirtualDisplay(options: opts)
        virtualDisplay = vd

        // サーバ
        let srv = FrameServer(port: hostPort, isH265: isH265, width: w, height: h)
        srv.onClientConnected = { [weak self] in
            DispatchQueue.main.async { self?.setState(.streaming) }
        }
        srv.onClientDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                self.setState(.waitingForClient)
            }
        }
        do {
            try srv.start()
        } catch {
            setState(.error("サーバ起動失敗: \(error.localizedDescription)"))
            return
        }
        server = srv
        AdbBridge.reverse(devicePort: devicePort, hostPort: hostPort)

        // エンコーダ
        let enc = VideoEncoder(width: w, height: h, codec: isH265 ? .h265 : .h264, bitrate: bitrateMbps * 1_000_000)
        enc.onEncoded = { [weak self] data, _ in
            self?.statEncoded += 1
            self?.statBytes += data.count
            self?.server?.sendAccessUnit(data)
        }
        do {
            try enc.start()
        } catch {
            setState(.error("エンコーダ起動失敗: \(error.localizedDescription)"))
            return
        }
        encoder = enc

        // キャプチャ
        let cap = ScreenCapturer(displayID: vd.displayID, width: w, height: h, fps: 60)
        cap.onFrame = { [weak self] imageBuffer, pts in
            guard let self = self else { return }
            self.statCaptured += 1
            if self.server?.isBacklogged == true { return }
            self.encoder?.encode(imageBuffer, pts: pts)
        }
        capturer = cap
        setState(.waitingForClient)
        startStatsTimer()

        Task { [weak self] in
            do {
                try await cap.start()
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.setState(.error("キャプチャ失敗（画面収録の許可を確認）: \(message)"))
                    self?.stop()
                }
            }
        }
    }

    func stop() {
        statTimer?.cancel()
        statTimer = nil
        AdbBridge.removeReverse(devicePort: devicePort)
        let cap = capturer
        Task { await cap?.stop() }
        capturer = nil
        encoder?.stop()
        encoder = nil
        server?.stop()
        server = nil
        virtualDisplay = nil // 解放で仮想ディスプレイ破棄
        statsText = ""
        setState(.stopped)
    }

    // MARK: - private

    private func setState(_ s: State) {
        if Thread.isMainThread {
            state = s
        } else {
            DispatchQueue.main.async { self.state = s }
        }
    }

    private func startStatsTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let cap = self.statCaptured, enc = self.statEncoded, kb = self.statBytes / 1024
            self.statCaptured = 0; self.statEncoded = 0; self.statBytes = 0
            DispatchQueue.main.async {
                self.statsText = "\(enc) fps / \(kb) KB/s（capture \(cap)）"
            }
        }
        t.resume()
        statTimer = t
    }
}
