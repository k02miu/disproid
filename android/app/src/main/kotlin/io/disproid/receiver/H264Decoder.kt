package io.disproid.receiver

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * H.264(Annex-B) を MediaCodec でデコードし Surface へ描画する。
 *
 * 性能・安定のための設計:
 *  - デコードを専用スレッドに分離し、ネイティブ(mirror RTP)スレッドを塞がない。
 *    onVideoFrame はフレームをコピーして有界キューへ積むだけ（滞留時は最古を破棄＝低遅延維持）。
 *  - 低遅延モード(KEY_LOW_LATENCY/PRIORITY)で glass-to-glass を短縮。
 *  - 開始/再接続時はキーフレーム(SPS/IDR)まで投入を待ち、初期の緑化・デコードエラーを回避。
 *  - ミラー終了で flush、解像度変化で再構成、例外時に再構成。
 */
class H264Decoder : VideoSink {

    private class Frame(@JvmField var data: ByteArray, @JvmField var len: Int, @JvmField var ptsUs: Long)

    private val queue = ArrayBlockingQueue<Frame>(QUEUE_CAP)

    // ByteArray プール（GC 圧を抑える）
    private val poolLock = Any()
    private val pool = ArrayDeque<ByteArray>()

    @Volatile private var surface: Surface? = null
    @Volatile private var running = false
    private var worker: Thread? = null

    @Volatile private var width = 1920
    @Volatile private var height = 1080
    @Volatile private var isH265 = false
    @Volatile private var pendingReconfigure = false
    @Volatile private var needFlush = false

    /** 最初のフレームを描画した瞬間に1度だけ呼ばれる（接続待ち表示を消す用）。 */
    @Volatile var onFirstFrame: (() -> Unit)? = null
    @Volatile private var firstFrameDone = false

    // 統計（1秒ごとにログ）
    private var statFed = 0
    private var statRendered = 0

    // ---- VideoSink（ネイティブスレッドから） ----

    override fun onVideoFormat(width: Int, height: Int) {
        if (width > 0 && height > 0 && (width != this.width || height != this.height)) {
            this.width = width
            this.height = height
            pendingReconfigure = true
        }
    }

    override fun onVideoFrame(buffer: ByteBuffer, len: Int, ptsUs: Long) {
        if (!running || len <= 0) return
        // バッファはこの呼び出し中のみ有効 → コピーしてキューへ。
        val arr = obtain(len)
        buffer.position(0)
        buffer.limit(len)
        buffer.get(arr, 0, len)
        val frame = Frame(arr, len, ptsUs)
        // P フレームを途中で捨てると参照が壊れて固まるため、ドロップせずブロッキングで詰める。
        // キューが満杯なら呼び出し元(受信スレッド)が待つ＝バックプレッシャー。
        // 送信側(Mac)はこの詰まりを検知してエンコード前に間引く。
        try {
            queue.put(frame)
        } catch (e: InterruptedException) {
            recycle(arr)
            Thread.currentThread().interrupt()
        }
    }

    override fun onMirrorState(running: Boolean) {
        if (!running) {
            clearQueue()
            needFlush = true   // 次接続に備えてデコーダをflushしキーフレーム待ちに戻す
        }
    }

    override fun onVideoCodec(isH265: Boolean) {
        if (this.isH265 != isH265) {
            this.isH265 = isH265
            pendingReconfigure = true  // MIME(avc/hevc)が変わるので再構成
            Log.i(TAG, "コーデック: ${if (isH265) "H.265/HEVC" else "H.264/AVC"}")
        }
    }

    // ---- ライフサイクル（UI スレッド） ----

    fun setSurface(s: Surface?) {
        if (s != null) {
            surface = s
            startWorker()
        } else {
            stopWorker()
            surface = null
        }
    }

    private fun startWorker() {
        if (worker != null) return
        running = true
        worker = Thread({ loop() }, "disproid-decoder").also { it.start() }
    }

    private fun stopWorker() {
        running = false
        worker?.let { try { it.join(800) } catch (_: InterruptedException) {} }
        worker = null
        clearQueue()
    }

    // ---- デコードループ（専用スレッド） ----

    private fun loop() {
        var codec: MediaCodec? = null
        var statT0 = System.currentTimeMillis()
        try {
            while (running) {
                val now = System.currentTimeMillis()
                if (now - statT0 >= 1000) {
                    if (Diag.VERBOSE) Log.i(TAG, "decode: fed=$statFed rendered=$statRendered /s (queue=${queue.size})")
                    statFed = 0; statRendered = 0; statT0 = now
                }
                val s = surface ?: run { Thread.sleep(5); null } ?: continue

                if (codec == null || pendingReconfigure) {
                    codec?.let { safeRelease(it) }
                    pendingReconfigure = false
                    codec = configure(s)
                    if (codec == null) { Thread.sleep(15); continue }
                }
                val c = codec!!

                if (needFlush) {
                    needFlush = false
                    try { c.flush() } catch (_: IllegalStateException) {}
                }

                val frame = queue.poll(15, TimeUnit.MILLISECONDS)
                if (frame != null) {
                    try {
                        // 全フレームを投入する。デコーダは内部でキーフレームまで出力を待つ。
                        feed(c, frame)
                    } catch (e: IllegalStateException) {
                        Log.e(TAG, "feed 失敗、再構成します", e)
                        safeRelease(c); codec = null
                    } finally {
                        recycle(frame.data)
                    }
                }
                codec?.let { drain(it) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "decoder loop 例外", e)
        } finally {
            codec?.let { safeRelease(it) }
        }
    }

    private fun feed(c: MediaCodec, f: Frame) {
        // 専用スレッドなのでここでのブロックは受信を阻害しない（最大 ~8ms 待つ）
        val inIdx = c.dequeueInputBuffer(8_000)
        if (inIdx < 0) return
        val ib = c.getInputBuffer(inIdx) ?: return
        ib.clear()
        if (f.len <= ib.remaining()) {
            ib.put(f.data, 0, f.len)
            c.queueInputBuffer(inIdx, 0, f.len, f.ptsUs, 0)
            statFed++
        } else {
            Log.w(TAG, "フレーム超過: ${f.len} > ${ib.remaining()}")
            c.queueInputBuffer(inIdx, 0, 0, f.ptsUs, 0)
        }
    }

    private fun drain(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var idx = c.dequeueOutputBuffer(info, 0)
        while (idx >= 0) {
            c.releaseOutputBuffer(idx, true) // render=true で Surface へ即描画
            statRendered++
            if (!firstFrameDone) {
                firstFrameDone = true
                onFirstFrame?.invoke()
            }
            idx = c.dequeueOutputBuffer(info, 0)
        }
    }

    private fun configure(s: Surface): MediaCodec? = try {
        val mime = if (isH265) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        val fmt = MediaFormat.createVideoFormat(mime, width, height)
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, 60)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1) // 低遅延モード
        }
        // realtime 優先（0=最高優先）
        fmt.setInteger(MediaFormat.KEY_PRIORITY, 0)
        val c = MediaCodec.createDecoderByType(mime)
        c.configure(fmt, s, null, 0)
        c.start()
        Log.i(TAG, "MediaCodec 構成: $mime ${width}x${height} lowLatency=${Build.VERSION.SDK_INT >= Build.VERSION_CODES.R}")
        c
    } catch (e: Exception) {
        Log.e(TAG, "MediaCodec 構成失敗", e)
        null
    }

    private fun safeRelease(c: MediaCodec) {
        try { c.stop() } catch (_: Exception) {}
        try { c.release() } catch (_: Exception) {}
    }

    // ---- ByteArray プール ----
    private fun obtain(len: Int): ByteArray {
        synchronized(poolLock) {
            val it = pool.iterator()
            while (it.hasNext()) {
                val a = it.next()
                if (a.size >= len) { it.remove(); return a }
            }
        }
        return ByteArray(maxOf(len, 64 * 1024))
    }

    private fun recycle(arr: ByteArray) {
        synchronized(poolLock) {
            if (pool.size < QUEUE_CAP + 2) pool.addLast(arr)
        }
    }

    private fun clearQueue() {
        while (true) {
            val f = queue.poll() ?: break
            recycle(f.data)
        }
    }

    companion object {
        private const val TAG = "DisproidReceiver"
        private const val QUEUE_CAP = 3  // 浅め＝低遅延。溢れたらブロックしてバックプレッシャー(ドロップしない)
    }
}
