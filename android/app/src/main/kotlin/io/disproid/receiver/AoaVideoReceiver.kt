package io.disproid.receiver

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.concurrent.thread

/**
 * AOA(USB Accessory) 経由で Mac ヘルパーから映像を受信する。
 *
 * adb を介さず、accessory のファイルディスクリプタ(/dev/usb_accessory)を直接読み書きする。
 * これにより adb トランスポートの切断(継続的 USB OUT で発生)を回避し、USB デバッグも不要になる。
 *
 * プロトコルは [UsbVideoReceiver] と共通（経路だけ LocalSocket → accessory FD に差し替え）:
 *   送信(1回): "DPRQ"(4) + width(4,BE) + height(4,BE)
 *   受信ヘッダ(14B): "DPRD" + version(1) + codec(1) + width(4,BE) + height(4,BE)
 *   以降くり返し: length(4,BE) + Annex-B アクセスユニット
 */
class AoaVideoReceiver(
    private val fd: ParcelFileDescriptor,
    private val sink: VideoSink,
    private val onFormat: (Int, Int) -> Unit,
    private val onError: (String) -> Unit,
    /** タブレットの実画面解像度。接続時に Mac へ通知し、Mac が一致する仮想ディスプレイを作る。 */
    private val deviceWidth: Int,
    private val deviceHeight: Int,
) {
    @Volatile private var running = false
    private var worker: Thread? = null
    private var input: FileInputStream? = null
    private var output: FileOutputStream? = null

    fun start() {
        if (running) return
        running = true
        worker = thread(name = "disproid-aoa-rx") { loop() }
    }

    fun stop() {
        running = false
        try { input?.close() } catch (_: Exception) {}
        try { output?.close() } catch (_: Exception) {}
        try { fd.close() } catch (_: Exception) {}
        input = null; output = null
        worker?.let { try { it.join(600) } catch (_: InterruptedException) {} }
        worker = null
    }

    // 受信蓄積バッファ。USB バルクは「転送境界」単位で read されるため、小さい read を繰り返すと
    // 1 転送の残りを取りこぼしてフレーミングがズレる。常に大きい read で蓄積し、必要分を切り出す。
    private var acc = ByteArray(1 shl 16)
    private var accOff = 0
    private var accLen = 0
    private val readChunk = ByteArray(1 shl 16)

    private fun loop() {
        var ptsUs = 0L
        try {
            val rawFd = fd.fileDescriptor
            val out = FileOutputStream(rawFd)
            val rawIn = FileInputStream(rawFd)
            output = out
            input = rawIn
            accOff = 0; accLen = 0

            // 接続要求: 自分の画面解像度を通知（"DPRQ" + width + height, BE）
            val dprq = ByteBuffer.allocate(12)
            dprq.put("DPRQ".toByteArray(Charsets.US_ASCII))
            dprq.putInt(deviceWidth)
            dprq.putInt(deviceHeight)
            out.write(dprq.array())
            out.flush()
            Log.i(TAG, "AOA 解像度を通知: ${deviceWidth}x${deviceHeight}")

            // ヘッダ(DPRD, 14B) を蓄積バッファ経由でちょうど読む
            val header = readExactly(rawIn, 14)
            if (String(header, 0, 4, Charsets.US_ASCII) != "DPRD") {
                onError("不正なヘッダ: ${String(header, 0, 4, Charsets.US_ASCII)}")
                return
            }
            val codec = header[5].toInt() and 0xff
            val width = beInt(header, 6)
            val height = beInt(header, 10)
            Log.i(TAG, "AOA 受信開始: codec=${if (codec == 1) "H265" else "H264"} ${width}x${height}")
            sink.onVideoCodec(codec == 1)
            sink.onVideoFormat(width, height)
            onFormat(width, height)

            var work = ByteArray(1 shl 20)
            val lenBuf = ByteArray(4)
            while (running) {
                readExactlyInto(rawIn, lenBuf, 4)
                val len = beInt(lenBuf, 0)
                if (len == 0) continue // キープアライブ
                if (len < 0 || len > MAX_AU_BYTES) {
                    Log.e(TAG, "異常なフレーム長: $len → ストリーム破損とみなす")
                    onError("ストリーム破損 (len=$len)")
                    return
                }
                if (len > work.size) work = ByteArray(len)
                readExactlyInto(rawIn, work, len)
                sink.onVideoFrame(ByteBuffer.wrap(work, 0, len), len, ptsUs)
                ptsUs += 16_666
            }
        } catch (e: Exception) {
            if (running) {
                Log.e(TAG, "AOA 受信エラー", e)
                onError(e.message ?: "AOA 接続エラー")
            }
        }
    }

    /** 蓄積バッファから n バイト切り出す（足りなければ大きい read で補充）。 */
    private fun readExactly(src: FileInputStream, n: Int): ByteArray {
        val out = ByteArray(n)
        readExactlyInto(src, out, n)
        return out
    }

    private fun readExactlyInto(src: FileInputStream, dst: ByteArray, n: Int) {
        var got = 0
        while (got < n) {
            if (accOff >= accLen) {
                // 蓄積が尽きた → 1 転送分を大きいバッファで読む（取りこぼし防止）
                val r = src.read(readChunk, 0, readChunk.size)
                if (r < 0) throw java.io.EOFException("accessory EOF")
                System.arraycopy(readChunk, 0, acc, 0, r)
                accOff = 0; accLen = r
                if (r == 0) continue
            }
            val take = minOf(n - got, accLen - accOff)
            System.arraycopy(acc, accOff, dst, got, take)
            accOff += take; got += take
        }
    }

    private fun beInt(b: ByteArray, o: Int): Int =
        ((b[o].toInt() and 0xff) shl 24) or ((b[o + 1].toInt() and 0xff) shl 16) or
            ((b[o + 2].toInt() and 0xff) shl 8) or (b[o + 3].toInt() and 0xff)

    companion object {
        private const val TAG = "DisproidReceiver"
        private const val MAX_AU_BYTES = 32 * 1024 * 1024
    }
}
