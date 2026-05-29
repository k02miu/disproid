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
        didSet {
            // GUI 指定は希望上限。手動変更したら実効ビットレートも追従させる。
            targetBitrateMbps = bitrateMbps
            applyEffectiveBitrate(bitrateMbps)
        }
    }

    private let devicePort: UInt16 = 27184
    private let hostPort: UInt16 = 27184
    private let isH265 = false

    private var virtualDisplay: VirtualDisplay?
    private var server: FrameServer?
    private var encoder: VideoEncoder?
    private var capturer: ScreenCapturer?
    private var statTimer: DispatchSourceTimer?
    private var reverseKeepAliveTimer: DispatchSourceTimer?
    /// App Nap 抑止トークン。配信中は macOS のスロットリング(タイマー遅延・送信途絶)を止める。
    /// これを怠ると、メイン画面使用中(拡張側が非アクティブ)にヘルパーが App Nap にかかり、
    /// 送信が途絶えてタブレット側の読み取りタイムアウトで切断される。
    private var activityToken: NSObjectProtocol?
    /// 現在構築済みのパイプラインの送出解像度。再接続時に作り直すか判定する。
    private var currentResolution: (Int, Int)?

    // 動的ビットレート適応: 切断が頻発したら実効ビットレートを下げ、安定したら希望値まで戻す。
    // adb reverse トンネルのスループット限界で起きる切断(RST)を、画質を諦めずに抑えるため。
    private let bitrateLadder = [4, 5, 6, 8, 10, 12, 15, 20, 40, 60]
    private var targetBitrateMbps = 20       // 希望上限(GUI 指定値)
    private var effectiveBitrateMbps = 20    // 実効(トンネルの安定度に応じ自動調整)
    private var lastDisconnect: DispatchTime?

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
        // 配信中は App Nap を抑止（バックグラウンド時のタイマー遅延・送信途絶を防ぐ）。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Disproid USB display streaming")
        targetBitrateMbps = bitrateMbps
        effectiveBitrateMbps = bitrateMbps
        lastDisconnect = nil

        let srv = FrameServer(port: hostPort, isH265: isH265)
        srv.onClientResolution = { [weak self] w, h in
            Task { @MainActor in await self?.handleClientResolution(w, h) }
        }
        srv.onClientDisconnected = { [weak self] in
            Task { @MainActor in await self?.handleClientDisconnected() }
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
        // USB トランスポートが落ちる(kIOReturnNotResponding)と reverse も消えるため、
        // keepalive で復旧する（消えている時だけ張り直す）。
        startReverseKeepAlive()
        setState(.waitingForClient)
    }

    func stop() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        statTimer?.cancel(); statTimer = nil
        reverseKeepAliveTimer?.cancel(); reverseKeepAliveTimer = nil
        teardownPipeline()
        server?.stop(); server = nil
        AdbBridge.removeReverse(devicePort: devicePort)
        statsText = ""
        activeResolution = ""
        setState(.stopped)
    }

    // MARK: - クライアント接続時にパイプラインを構築

    @MainActor
    private func handleClientResolution(_ w: Int, _ h: Int) async {
        guard isRunning else { return }

        // 目標解像度: 自動ならタブレット通知値、固定なら GUI 指定。偶数化。
        let tw = (autoResolution ? w : width).evenized
        let th = (autoResolution ? h : height).evenized
        guard tw > 0, th > 0 else {
            setState(.error("解像度が不正: \(tw)x\(th)"))
            return
        }

        // 解像度が前回と同じでパイプラインが生きていれば作り直さない。
        // 仮想ディスプレイの作り直しは失敗しやすく(displayID=0)、画面のちらつきや
        // 自己増幅的な不安定の原因になる。再接続時はキーフレームを1枚送るだけで即復帰させる。
        if capturer != nil, let cur = currentResolution, cur == (tw, th) {
            adaptOnDisconnect()  // 再接続＝直前に切断があった。頻発するほどビットレートを下げる
            server?.sendHeader(width: tw, height: th)  // 先にヘッダを送ってゲートを開く
            encoder?.requestKeyframe()                  // その後キーフレームを要求
            activeResolution = "\(tw) × \(th)"
            setState(.streaming)
            return
        }

        // 解像度が変わった or 初回 → パイプラインを作り直す（前のを確実に破棄してから）。
        await teardownPipelineAsync()

        // 仮想ディスプレイ
        var opts = Options()
        opts.width = UInt32(tw)
        opts.height = UInt32(th)
        opts.name = "Disproid Virtual Display"
        let vd = VirtualDisplay(options: opts)
        virtualDisplay = vd

        // エンコーダ
        let enc = VideoEncoder(width: tw, height: th, codec: isH265 ? .h265 : .h264, bitrate: effectiveBitrateMbps * 1_000_000)
        enc.onEncoded = { [weak self] data, _ in
            self?.statEncoded += 1
            self?.statBytes += data.count
            self?.server?.sendAccessUnit(data)
        }
        do {
            try enc.start()
        } catch {
            // エンコーダ起動失敗。全停止すると復旧不能になるため、畳んで接続待ちに戻す。
            FileHandle.standardError.write(Data("[engine] エンコーダ起動失敗: \(error.localizedDescription) → 接続待ちに戻す\n".utf8))
            await teardownPipelineAsync()
            server?.dropConnection()
            if isRunning { setState(.waitingForClient) }
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

        // キャプチャ起動（仮想ディスプレイ登録の伝播待ちでリトライあり）。
        // 起動が成功してからヘッダを送る（映像の来ない受信開始状態で固まるのを防ぐ）。
        do {
            try await cap.start()
        } catch {
            // キャプチャ起動失敗。停止せずパイプラインを畳み、接続を切って待ち受けに戻す。
            // タブレットの再接続でやり直せる（自己署名で TCC は維持されている前提）。
            FileHandle.standardError.write(Data("[engine] キャプチャ起動失敗: \(error.localizedDescription) → 接続待ちに戻す\n".utf8))
            await teardownPipelineAsync()
            server?.dropConnection()
            if isRunning { setState(.waitingForClient) }
            return
        }

        // ヘッダ送信（実際の送出解像度）
        currentResolution = (tw, th)
        server?.sendHeader(width: tw, height: th)
        activeResolution = "\(tw) × \(th)"
        setState(.streaming)
    }

    @MainActor
    private func handleClientDisconnected() async {
        // パイプラインは破棄せず維持する。次の接続でキーフレームを1枚送るだけで即再開でき、
        // 仮想ディスプレイの作り直しに伴う失敗(displayID=0)・ちらつきを避けられる。
        // 完全停止はメニューバーの「停止」(stop)でのみ行う。
        if isRunning { setState(.waitingForClient) }
    }

    /// パイプラインを破棄し、キャプチャ停止の完了まで待つ。
    /// 先に capturer を nil 化してから停止を待つことで、並行する再構築との二重停止を避ける。
    @MainActor
    private func teardownPipelineAsync() async {
        let cap = capturer
        capturer = nil
        encoder?.stop(); encoder = nil
        virtualDisplay = nil
        currentResolution = nil
        if let cap = cap { await cap.stop() }
    }

    /// 同期版（stop() からのみ使用。終了時はキャプチャ停止を待たずに投げる）。
    private func teardownPipeline() {
        let cap = capturer
        Task { await cap?.stop() }
        capturer = nil
        encoder?.stop(); encoder = nil
        virtualDisplay = nil
        currentResolution = nil
    }

    // MARK: - 動的ビットレート適応

    /// 実効ビットレートを設定しエンコーダへ反映する（MainActor 前提）。
    private func applyEffectiveBitrate(_ mbps: Int) {
        effectiveBitrateMbps = mbps
        encoder?.setBitrate(mbps * 1_000_000)
    }

    /// 再接続(=直前に切断)を検知したら実効ビットレートを1段下げる（MainActor 前提）。
    /// 下げた後 30 秒安定すれば recoverBitrateIfStable が1段ずつ希望値まで戻す。
    private func adaptOnDisconnect() {
        lastDisconnect = DispatchTime.now()
        guard let idx = bitrateLadder.firstIndex(of: effectiveBitrateMbps), idx > 0 else { return }
        let lower = bitrateLadder[idx - 1]
        applyEffectiveBitrate(lower)
        FileHandle.standardError.write(Data("[engine] 切断 → ビットレートを \(lower)Mbps に自動ダウン\n".utf8))
    }

    /// 一定時間切断が無ければ実効ビットレートを1段、希望値まで引き上げる（MainActor 前提）。
    private func recoverBitrateIfStable() {
        guard effectiveBitrateMbps < targetBitrateMbps, let last = lastDisconnect else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds
        guard elapsed > 30_000_000_000 else { return }  // 30秒安定したら回復
        guard let idx = bitrateLadder.firstIndex(of: effectiveBitrateMbps), idx + 1 < bitrateLadder.count else { return }
        let next = bitrateLadder[idx + 1]
        guard next <= targetBitrateMbps else { return }
        lastDisconnect = DispatchTime.now()  // 次の引き上げまでまた30秒様子見
        applyEffectiveBitrate(next)
        FileHandle.standardError.write(Data("[engine] 安定 → ビットレートを \(next)Mbps に回復\n".utf8))
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
            DispatchQueue.main.async {
                self.statsText = "\(enc) fps / \(kb) KB/s / \(self.effectiveBitrateMbps)Mbps"
                self.recoverBitrateIfStable()
            }
        }
        t.resume()
        statTimer = t
    }

    /// `adb reverse` トンネルを稼働中ずっと維持する。
    /// USB の瞬断・adb daemon 再起動・キャプチャエラー時の自己 stop などで
    /// トンネルが消えると、タブレットは localhost:27184 に繋げず復旧できない
    /// （reverse はホスト=Mac 側からしか張れない）。冪等な reverse を定期実行し、
    /// 消えていれば張り直して「固まったら二度と戻らない」を防ぐ。
    private func startReverseKeepAlive() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        // 短間隔で確認。USB 切断で reverse が消えても素早く張り直し、再接続を 1 秒以内に縮める。
        t.schedule(deadline: .now() + 0.3, repeating: 0.3)
        t.setEventHandler { [weak self] in
            guard let self = self, self.isRunning else { return }
            // 既に張られていれば再設定しない。adb reverse の再設定は進行中の USB 接続を
            // EOF で切ってしまい、再接続ループの原因になる。トンネルが消えている時だけ張り直す。
            if !AdbBridge.isReversed(devicePort: self.devicePort) {
                AdbBridge.reverse(devicePort: self.devicePort, hostPort: self.hostPort)
            }
        }
        t.resume()
        reverseKeepAliveTimer = t
    }
}

private extension Int {
    var evenized: Int { self - (self % 2) }
}
