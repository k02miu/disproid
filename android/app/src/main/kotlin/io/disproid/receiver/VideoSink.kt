package io.disproid.receiver

import java.nio.ByteBuffer

/**
 * ネイティブ AirPlay コアから映像情報・フレームを受け取るインターフェース。
 * これらは **mirror RTP のネイティブスレッド**から呼ばれる（UI スレッドではない）。
 * onVideoFrame の buffer は呼び出し中のみ有効な direct ByteBuffer。同期的にコピーすること。
 */
interface VideoSink {
    /** 映像サイズ通知（video_report_size 由来。ソース解像度）。 */
    fun onVideoFormat(width: Int, height: Int)

    /** H.264 Annex-B フレーム（SPS/PPS は IDR 先頭に prepend 済み）。 */
    fun onVideoFrame(buffer: ByteBuffer, len: Int, ptsUs: Long)

    /** ミラーリングの開始/終了。 */
    fun onMirrorState(running: Boolean)

    /** コーデック通知（true=H.265/HEVC, false=H.264）。フレーム到着前に呼ばれる。 */
    fun onVideoCodec(isH265: Boolean)
}
