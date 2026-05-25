import Foundation
import Combine
import CoreGraphics

/// 仮想ディスプレイ生成 → キャプチャ → エンコード → USB(adb) 送信、の一連を管理する。
/// クライアント(タブレット)が接続時に解像度を通知し、Mac はそれに合わせて
/// （または固定指定で）仮想ディスプレイを作る。
final class StreamEngine: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case waitingForClient
        case streaming
        case error(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var statsText: String = ""
    @Published private(set) var activeResolution: String = ""

    /// 自動（タブレット解像度に合わせる）。false なら下の width/height を使う。
    @Published var autoResolution: Bool = true
    @Published var width: Int = 1920
    @Published var height: Int = 1080
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

    private var statCaptured = 0
    private var statEncoded = 0
    private var statBytes = 0

    var isRunning: Bool {
        switch state {
        case .stopped, .error: return false
        default: return true
        }
    }

    // MARK: - 開始/停止

    func start() {
        guard !isRunning else { return }
        setState(.starting)

        let srv = FrameServer(port: hostPort, isH265: isH265)
        srv.onClientResolution = { [weak self] w, h in
            DispatchQueue.main.async { self?.handleClientResolution(w, h) }
        }
        srv.onClientDisconnected = { [weak self] in
            DispatchQueue.main.async { self?.handleClientDisconnected() }
        }
        do {
            try srv.start()
        } catch {
            setState(.error("サーバ起動失敗: \(error.localizedDescription)"))
            return
        }
        server = srv
        AdbBridge.reverse(devicePort: devicePort, hostPort: hostPort)
        startStatsTimer()
        setState(.waitingForClient)
    }

    func stop() {
        statTimer?.cancel(); statTimer = nil
        teardownPipeline()
        server?.stop(); server = nil
        AdbBridge.removeReverse(devicePort: devicePort)
        statsText = ""
        activeResolution = ""
        setState(.stopped)
    }

    // MARK: - クライアント接続時にパイプラインを構築

    private func handleClientResolution(_ w: Int, _ h: Int) {
        guard isRunning else { return }
        teardownPipeline()  // 再接続に備え既存を破棄

        // 目標解像度: 自動ならタブレット通知値、固定なら GUI 指定。偶数化。
        let tw = (autoResolution ? w : width).evenized
        let th = (autoResolution ? h : height).evenized
        guard tw > 0, th > 0 else {
            setState(.error("解像度が不正: \(tw)x\(th)"))
            return
        }

        // 仮想ディスプレイ
        var opts = Options()
        opts.width = UInt32(tw)
        opts.height = UInt32(th)
        opts.name = "Disproid Virtual Display"
        let vd = VirtualDisplay(options: opts)
        virtualDisplay = vd

        // エンコーダ
        let enc = VideoEncoder(width: tw, height: th, codec: isH265 ? .h265 : .h264, bitrate: bitrateMbps * 1_000_000)
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
        let cap = ScreenCapturer(displayID: vd.displayID, width: tw, height: th, fps: 60)
        cap.onFrame = { [weak self] imageBuffer, pts in
            guard let self = self else { return }
            self.statCaptured += 1
            if self.server?.isBacklogged == true { return }
            self.encoder?.encode(imageBuffer, pts: pts)
        }
        capturer = cap

        // ヘッダ送信（実際の送出解像度）
        server?.sendHeader(width: tw, height: th)
        activeResolution = "\(tw) × \(th)"
        setState(.streaming)

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

    private func handleClientDisconnected() {
        teardownPipeline()
        if isRunning { setState(.waitingForClient) }
    }

    private func teardownPipeline() {
        let cap = capturer
        Task { await cap?.stop() }
        capturer = nil
        encoder?.stop(); encoder = nil
        virtualDisplay = nil
    }

    // MARK: - private

    private func setState(_ s: State) {
        if Thread.isMainThread { state = s }
        else { DispatchQueue.main.async { self.state = s } }
    }

    private func startStatsTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let enc = self.statEncoded, kb = self.statBytes / 1024
            self.statCaptured = 0; self.statEncoded = 0; self.statBytes = 0
            DispatchQueue.main.async { self.statsText = "\(enc) fps / \(kb) KB/s" }
        }
        t.resume()
        statTimer = t
    }
}

private extension Int {
    var evenized: Int { self - (self % 2) }
}
