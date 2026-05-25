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
    private let maxInFlight = 2

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
        FileHandle.standardError.write(Data("[server] listen on 127.0.0.1:\(port)\n".utf8))
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        lock.lock(); inFlight = 0; lock.unlock()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.onClientDisconnected?()
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
    }

    /// Annex-B アクセスユニットを 4 バイト長前置で送る。
    func sendAccessUnit(_ data: Data) {
        guard let conn = connection else { return }
        var framed = Data()
        framed.append(beData(UInt32(data.count)))
        framed.append(data)
        lock.lock(); inFlight += 1; lock.unlock()
        conn.send(content: framed, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
        })
    }

    func stop() {
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
