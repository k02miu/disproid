import Foundation
import Network

/// localhost で待ち受け、接続してきたクライアント（adb reverse 経由の Android）へ
/// 映像ストリームを送る TCP サーバ。
///
/// プロトコル:
///   1. クライアント→サーバ: "DPRQ"(4) + width(4,BE) + height(4,BE)  … タブレットの画面解像度
///   2. サーバ→クライアント(ヘッダ14B): "DPRD"(4) + version(1) + codec(1) + width(4,BE) + height(4,BE)
///   3. 以降くり返し: length(4,BE) + Annex-B アクセスユニット
final class FrameServer {

    private let port: UInt16
    private let codecByte: UInt8
    private let queue = DispatchQueue(label: "io.disproid.server")
    private var listener: NWListener?
    private var connection: NWConnection?

    // 送信バックログ（未完了の送信数）。詰まっている間は送信側で間引く判断に使う。
    private let lock = NSLock()
    private var inFlight = 0
    // 未完了送信の上限。adb トンネルへの瞬間的な積み上げ(→RST)を防ぐため浅めにする。
    private let maxInFlight = 1
    // ヘッダ(DPRD)送信が済むまでアクセスユニットを送らないためのゲート。
    // パイプライン再利用時、新接続にヘッダより先にフレームが届くと境界が壊れるのを防ぐ。
    private var headerSent = false
    // アイドル(画面静止でフレーム送信が途絶える)中も adb トンネルを維持するためのキープアライブ。
    // 一定時間送信が無ければ length=0 の空フレームを流し、adb の idle 切断(EOF/RST)を防ぐ。
    private var lastSendTime = DispatchTime.now()
    private var keepAliveTimer: DispatchSourceTimer?

    var isBacklogged: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight >= maxInFlight
    }

    /// クライアントが解像度を通知してきた（任意スレッド）。これを受けて Mac 側でパイプラインを構築する。
    var onClientResolution: ((Int, Int) -> Void)?
    var onClientDisconnected: (() -> Void)?

    init(port: UInt16, isH265: Bool) {
        self.port = port
        self.codecByte = isH265 ? 1 : 0
    }

    func start() throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        startKeepAlive()
        FileHandle.standardError.write(Data("[server] listen on 127.0.0.1:\(port)\n".utf8))
    }

    /// アイドル中も adb トンネルを維持する。一定時間フレーム送信が無ければ length=0 の
    /// 空フレームを送り、adb の idle 切断を防ぐ（画面静止・断続更新で切れる対策）。
    private func startKeepAlive() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)  // 50ms ごとに確認
        t.setEventHandler { [weak self] in
            guard let self = self, let conn = self.connection else { return }
            self.lock.lock()
            let ready = self.headerSent
            let idleNs = DispatchTime.now().uptimeNanoseconds &- self.lastSendTime.uptimeNanoseconds
            self.lock.unlock()
            guard ready, idleNs > 100_000_000 else { return }  // 100ms 送信が途絶えたら
            self.lock.lock(); self.lastSendTime = DispatchTime.now(); self.lock.unlock()
            conn.send(content: self.beData(0), completion: .contentProcessed { _ in })
        }
        t.resume()
        keepAliveTimer = t
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        lock.lock(); inFlight = 0; headerSent = false; lock.unlock()
        // 切断検知: この接続が今もアクティブな場合のみ通知する。
        // 新接続による置き換えで古い接続を cancel した時は、ここでは何もしない
        // （そうしないと新パイプラインを巻き込んで teardown してしまう）。
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .failed(let error):
                FileHandle.standardError.write(Data("[server] 接続が .failed: \(error)\n".utf8))
                guard let self = self, let conn = conn, self.connection === conn else { return }
                self.connection = nil  // 以降のフレーム送信を止める（切れた接続への ENOTCONN スパム防止）
                self.onClientDisconnected?()
            case .cancelled:
                guard let self = self, let conn = conn, self.connection === conn else { return }
                self.onClientDisconnected?()
            default:
                break
            }
        }
        conn.start(queue: queue)
        // クライアントの解像度要求(12B)を受信
        conn.receive(minimumIncompleteLength: 12, maximumLength: 12) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count >= 12 else { return }
            let bytes = [UInt8](data)
            let magic = String(decoding: bytes[0..<4], as: UTF8.self)
            guard magic == "DPRQ" else {
                FileHandle.standardError.write(Data("[server] 不正な要求ヘッダ\n".utf8))
                return
            }
            let w = Int(Self.beUInt32(bytes, 4))
            let h = Int(Self.beUInt32(bytes, 8))
            FileHandle.standardError.write(Data("[server] client connected, 要求解像度 \(w)x\(h)\n".utf8))
            self.onClientResolution?(w, h)
        }
    }

    /// パイプライン構築後にヘッダを送る（実際の送出解像度を入れる）。
    func sendHeader(width: Int, height: Int) {
        guard let conn = connection else { return }
        var h = Data()
        h.append(contentsOf: Array("DPRD".utf8))
        h.append(1) // version
        h.append(codecByte)
        h.append(beData(UInt32(width)))
        h.append(beData(UInt32(height)))
        conn.send(content: h, completion: .contentProcessed { _ in })
        lock.lock(); headerSent = true; lastSendTime = DispatchTime.now(); lock.unlock()
    }

    /// Annex-B アクセスユニットを 4 バイト長前置で送る。
    func sendAccessUnit(_ data: Data) {
        guard let conn = connection else { return }
        lock.lock(); let ready = headerSent; lock.unlock()
        guard ready else { return }  // ヘッダ送信前のフレームは捨てる（Android の境界誤読を防ぐ）
        var framed = Data()
        framed.append(beData(UInt32(data.count)))
        framed.append(data)
        lock.lock(); inFlight += 1; lastSendTime = DispatchTime.now(); lock.unlock()
        conn.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                FileHandle.standardError.write(Data("[server] send 失敗: \(error)\n".utf8))
            }
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
        })
    }

    /// 現在のクライアント接続だけを切る（listener は維持）。
    /// パイプライン構築に失敗した時などに呼び、タブレット側のクリーンな再接続を促す。
    func dropConnection() {
        connection?.cancel()
        connection = nil
    }

    func stop() {
        keepAliveTimer?.cancel(); keepAliveTimer = nil
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    private func beData(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func beUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }
}
