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

    init(port: UInt16, isH265: Bool, width: Int, height: Int) {
        self.port = port
        self.codecByte = isH265 ? 1 : 0
        self.width = UInt32(width)
        self.height = UInt32(height)
    }

    func start() throws {
        let params = NWParameters.tcp
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
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                FileHandle.standardError.write(Data("[server] client connected\n".utf8))
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
        conn.send(content: framed, completion: .contentProcessed { _ in })
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
