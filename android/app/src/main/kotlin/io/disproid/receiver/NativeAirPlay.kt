package io.disproid.receiver

/**
 * UxPlay ベースのネイティブ AirPlay コア（libdisproid.so）への JNI 入口。
 *
 * raop(HTTP/RTSP)サーバの起動/停止と、映像 sink の登録を担う。
 * mDNS 広告自体は Kotlin の NsdManager が担当し、ここは listen ポートと公開鍵を返す。
 */
object NativeAirPlay {
    init {
        System.loadLibrary("disproid")
    }

    /**
     * ネイティブ raop サーバを起動する。
     * @param deviceId "XX:XX:XX:XX:XX:XX" 形式
     * @param name 表示名
     * @param keyfile ed25519 鍵の永続化先パス（null 可。null だと毎回生成）
     * @param width  タブレット実ディスプレイの幅(px, landscape の長辺)。/info で Mac に報告
     * @param height タブレット実ディスプレイの高さ(px, landscape の短辺)
     * @param refreshRate ディスプレイのリフレッシュレート(Hz)
     * @return listen ポート番号。失敗時は負値。
     */
    external fun nativeStart(
        deviceId: String,
        name: String,
        keyfile: String?,
        width: Int,
        height: Int,
        refreshRate: Int,
    ): Int

    /** raop が生成した ed25519 公開鍵(hex)。mDNS 広告の pk と一致させるために使う。 */
    external fun nativeGetPublicKey(): String

    /** 映像フレームの受け取り先（[VideoSink]）を登録/解除する。null で解除。 */
    external fun nativeSetVideoSink(sink: VideoSink?)

    /** ネイティブ raop サーバを停止・破棄する。 */
    external fun nativeStop()
}
