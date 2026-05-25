package io.disproid.receiver

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * H.264(Annex-B) を MediaCodec でデコードし Surface に直接描画する。
 *
 * UxPlay の video_process は Annex-B（00 00 00 01 区切り、SPS/PPS は IDR 先頭に prepend）で
 * フレームを渡すため、in-band の SPS/PPS でデコーダが構成される。
 *
 * onVideoFrame はネイティブ(mirror RTP)スレッドから同期的に呼ばれる。
 * Surface の設定/解除は UI スレッド。両者を [lock] で保護する。
 */
class H264Decoder : VideoSink {

    private val lock = Any()
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var width = 1920
    private var height = 1080

    fun setSurface(s: Surface?) {
        synchronized(lock) {
            surface = s
            if (s == null) releaseCodecLocked()
        }
    }

    override fun onVideoFormat(width: Int, height: Int) {
        synchronized(lock) {
            if (width > 0 && height > 0) {
                this.width = width
                this.height = height
            }
        }
    }

    override fun onMirrorState(running: Boolean) {
        if (!running) {
            synchronized(lock) { releaseCodecLocked() }
        }
    }

    override fun onVideoFrame(buffer: ByteBuffer, len: Int, ptsUs: Long) {
        synchronized(lock) {
            val s = surface ?: return
            val c = ensureCodecLocked(s) ?: return
            try {
                val inIdx = c.dequeueInputBuffer(IN_TIMEOUT_US)
                if (inIdx >= 0) {
                    val ib = c.getInputBuffer(inIdx) ?: return
                    ib.clear()
                    buffer.position(0)
                    buffer.limit(len)
                    if (len <= ib.remaining()) {
                        ib.put(buffer)
                        c.queueInputBuffer(inIdx, 0, len, ptsUs, 0)
                    } else {
                        // 入力バッファより大きいフレーム（通常起きない）。今回は破棄。
                        Log.w(TAG, "フレームが入力バッファ超過: $len > ${ib.remaining()}")
                        c.queueInputBuffer(inIdx, 0, 0, ptsUs, 0)
                    }
                }
                // 出力を Surface に描画
                val info = MediaCodec.BufferInfo()
                var outIdx = c.dequeueOutputBuffer(info, 0)
                while (outIdx >= 0) {
                    c.releaseOutputBuffer(outIdx, true) // render=true
                    outIdx = c.dequeueOutputBuffer(info, 0)
                }
            } catch (e: IllegalStateException) {
                Log.e(TAG, "デコード中エラー、再構成します", e)
                releaseCodecLocked()
            }
        }
    }

    private fun ensureCodecLocked(s: Surface): MediaCodec? {
        codec?.let { return it }
        return try {
            val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            c.configure(fmt, s, null, 0)
            c.start()
            Log.i(TAG, "MediaCodec(video/avc) 構成: ${width}x${height}")
            codec = c
            c
        } catch (e: Exception) {
            Log.e(TAG, "MediaCodec 構成失敗", e)
            null
        }
    }

    private fun releaseCodecLocked() {
        codec?.let {
            try { it.stop() } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
            Log.i(TAG, "MediaCodec 解放")
        }
        codec = null
    }

    companion object {
        private const val TAG = "DisproidReceiver"
        private const val IN_TIMEOUT_US = 10_000L
    }
}
