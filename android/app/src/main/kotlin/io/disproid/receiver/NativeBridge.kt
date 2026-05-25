package io.disproid.receiver

import android.os.Handler
import android.os.Looper
import java.nio.ByteBuffer

/**
 * JNI に登録する唯一の [VideoSink]。ネイティブからの呼び出しを
 *  - フレーム/サイズ → 現在の描画先（[frameSink] = MirrorActivity の H264Decoder）
 *  - ミラー開始/終了 → [mirrorListener]（Service が MirrorActivity を起動）
 * へ振り分ける。描画先が未接続のフレームは破棄する。
 *
 * onVideoFrame は毎フレーム・ネイティブスレッドで呼ばれるため、転送は同期・無加工で行う。
 */
object NativeBridge : VideoSink {

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 実描画先（MirrorActivity の Surface が準備できたら設定される）。 */
    @Volatile var frameSink: VideoSink? = null

    /** ミラー状態リスナ（Service が登録）。メインスレッドで呼ぶ。 */
    @Volatile var mirrorListener: ((Boolean) -> Unit)? = null

    @Volatile var sourceWidth: Int = 1920
        private set
    @Volatile var sourceHeight: Int = 1080
        private set

    override fun onVideoFormat(width: Int, height: Int) {
        if (width > 0 && height > 0) {
            sourceWidth = width
            sourceHeight = height
        }
        frameSink?.onVideoFormat(width, height)
    }

    override fun onVideoFrame(buffer: ByteBuffer, len: Int, ptsUs: Long) {
        // ネイティブスレッドで同期処理（buffer はこの呼び出し中のみ有効）
        frameSink?.onVideoFrame(buffer, len, ptsUs)
    }

    override fun onMirrorState(running: Boolean) {
        mainHandler.post { mirrorListener?.invoke(running) }
        frameSink?.onMirrorState(running)
    }
}
