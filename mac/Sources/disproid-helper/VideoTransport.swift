import Foundation

/// 映像ストリームの送出経路を抽象化するプロトコル。
/// adb reverse 経由の TCP (`FrameServer`) と AOA バルク (`AoaTransport`) を
/// `StreamEngine` から同一インタフェースで差し替えられるようにする。
///
/// プロトコル本体（DPRQ/DPRD + length+AnnexB）は経路非依存で共通。
protocol VideoTransport: AnyObject {
    /// クライアント(タブレット)が解像度を通知してきた（任意スレッド）。
    var onClientResolution: ((Int, Int) -> Void)? { get set }
    /// クライアントが切断した（任意スレッド）。
    var onClientDisconnected: (() -> Void)? { get set }
    /// 送信バックログ。詰まっている間はエンコード前にキャプチャを間引く判断に使う。
    var isBacklogged: Bool { get }

    /// 待ち受け/接続を開始する。
    func start() throws
    /// 送出解像度のヘッダ(DPRD)を送る。
    func sendHeader(width: Int, height: Int)
    /// Annex-B アクセスユニットを length 前置で送る。
    func sendAccessUnit(_ data: Data)
    /// 現在のクライアント接続のみ切る（待ち受けは維持）。
    func dropConnection()
    /// 全停止。
    func stop()
}
