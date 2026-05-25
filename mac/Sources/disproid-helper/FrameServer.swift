import Foundation
import Network

/// localhost で待ち受け、接続してきたクライアント（adb reverse 経由の Android）へ
/// 映像ストリームを送る TCP サーバ。
///
/// プロトコル:
///   ヘッダ(14B): "DPRD"(4) + version(1) + codec(1: 0=H264,1=H265) + width(4, BE) + height(4, BE)
///   以降くり返し: length(4, BE) + Annex-B アクセスユニット(length バイト)
final class FrameServer {

    private let port: UInt16
    private let codecByte: UInt8
    private let width: UInt32
    private let height: UInt32
    private let queue = DispatchQueue(label: "io.disproid.server")
    private var listener: NWListener?
    private var connection: NWConnection?

    // 送信バックログ（未完了の送信数）。詰まっている間は送信側で間引く判断に使う。
    private let lock = NSLock()
    private var inFlight = 0
    private let maxInFlight = 2

    /// 送信が詰まっている（= 受信側が遅れている）か。true の間はエンコードをスキップして良い。
    var isBacklogged: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight >= maxInFlight
    }

    /// クライアント接続/切断の通知（任意のスレッドから呼ばれる）。
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    init(port: UInt16, isH265: Bool, width: Int, height: Int) {
        self.port = port
        self.codecByte = isH265 ? 1 : 0
        self.width = UInt32(width)
        self.height = UInt32(height)
    }

    func start() throws {
        // Nagle 無効（低遅延）
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
        // 単一クライアント前提。既存接続は破棄して差し替え。
        connection?.cancel()
        connection = conn
        lock.lock(); inFlight = 0; lock.unlock()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                FileHandle.standardError.write(Data("[server] client connected\n".utf8))
                self?.onClientConnected?()
            case .failed, .cancelled:
                self?.onClientDisconnected?()
            default:
                break
            }
        }
        conn.start(queue: queue)
        sendHeader(conn)
    }

    private func sendHeader(_ conn: NWConnection) {
        var h = Data()
        h.append(contentsOf: Array("DPRD".utf8))
        h.append(1) // version
        h.append(codecByte)
        h.append(beUInt32(width))
        h.append(beUInt32(height))
        conn.send(content: h, completion: .contentProcessed { _ in })
    }

    /// Annex-B アクセスユニットを 4 バイト長前置で送る。
    func sendAccessUnit(_ data: Data) {
        guard let conn = connection else { return }
        var framed = Data()
        framed.append(beUInt32(UInt32(data.count)))
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

    private func beUInt32(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }
}
