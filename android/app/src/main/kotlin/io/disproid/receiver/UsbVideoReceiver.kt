package io.disproid.receiver

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import java.io.DataInputStream
import java.nio.ByteBuffer
import kotlin.concurrent.thread

/**
 * USB(adb reverse) 経由で Mac ヘルパーから映像を受信する。
 *
 * Mac ヘルパーが `adb reverse localabstract:disproid tcp:27184` を設定済みなので、
 * 端末側の abstract Unix domain socket "disproid" へ接続すると Mac の FrameServer に届く。
 * （tcp ループバックを使わず scrcpy と同じ abstract socket にすることで、
 *  端末側 TCP スタックを経由させず adb トランスポートの安定性を上げる狙い）
 *
 * プロトコル（FrameServer.swift と一致）:
 *   ヘッダ(14B): "DPRD" + version(1) + codec(1: 0=H264,1=H265) + width(4,BE) + height(4,BE)
 *   以降くり返し: length(4,BE) + Annex-B アクセスユニット
 */
class UsbVideoReceiver(
    private val sink: VideoSink,
    private val onFormat: (Int, Int) -> Unit,
    private val onError: (String) -> Unit,
    /** タブレットの実画面解像度(landscape)。接続時に Mac へ通知し、Mac が一致する仮想ディスプレイを作る。 */
    private val deviceWidth: Int,
    private val deviceHeight: Int,
) {
    @Volatile private var running = false
    private var socket: LocalSocket? = null
    private var worker: Thread? = null

    fun start() {
        if (running) return
        running = true
        worker = thread(name = "disproid-usb-rx") { loop() }
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        worker?.let { try { it.join(600) } catch (_: InterruptedException) {} }
        worker = null
    }

    private fun loop() {
        var ptsUs = 0L
        try {
            val s = LocalSocket()
            s.connect(LocalSocketAddress(ABSTRACT_NAME, LocalSocketAddress.Namespace.ABSTRACT))
            // 読み取りタイムアウト。adb トンネルが切れずに転送停止する「ハーフ詰まり」
            // (接続は生きているのにデータが来ない)を検知し、再接続で復帰させる。
            s.soTimeout = READ_TIMEOUT_MS
            socket = s

            // 接続要求: 自分の画面解像度を通知（"DPRQ" + width + height, BE）
            val out = java.io.DataOutputStream(s.outputStream)
            out.writeBytes("DPRQ")
            out.writeInt(deviceWidth)
            out.writeInt(deviceHeight)
            out.flush()
            Log.i(TAG, "解像度を通知: ${deviceWidth}x${deviceHeight}")

            val input = DataInputStream(s.inputStream.buffered(1 shl 16))

            // ヘッダ
            val magic = ByteArray(4)
            input.readFully(magic)
            if (String(magic) != "DPRD") {
                onError("不正なヘッダ: ${String(magic)}")
                return
            }
            input.readUnsignedByte() // version
            val codec = input.readUnsignedByte()
            val width = input.readInt()  // BE
            val height = input.readInt()
            Log.i(TAG, "USB 受信開始: codec=${if (codec == 1) "H265" else "H264"} ${width}x${height}")
            sink.onVideoCodec(codec == 1)
            sink.onVideoFormat(width, height)
            onFormat(width, height)

            val buf = ByteArray(1 shl 20) // 1MB 初期
            var work = buf
            var statFrames = 0
            var statBytes = 0L
            var statT0 = System.currentTimeMillis()
            while (running) {
                val len = input.readInt() // アクセスユニット長(BE)
                // 正常な access unit は高々数 MB。範囲外の長さを読んだらフレーム境界が
                // ズレた(ストリーム破損)とみなす。巨大値で ByteArray を確保すると OOM で
                // プロセスごと落ちるため、その前に接続を捨てて再接続させる
                // (再接続すれば Mac が必ずキーフレームから送り直すので復帰する)。
                if (len == 0) continue  // キープアライブ（adb トンネル維持用の空フレーム）。読み飛ばす
                if (len < 0 || len > MAX_AU_BYTES) {
                    Log.e(TAG, "異常なフレーム長: $len → ストリーム破損とみなし再接続")
                    onError("ストリーム破損 (len=$len)")
                    return
                }
                if (len > work.size) work = ByteArray(len)
                input.readFully(work, 0, len)
                sink.onVideoFrame(ByteBuffer.wrap(work, 0, len), len, ptsUs)
                ptsUs += 16_666 // 約60fps 相当の擬似 pts

                statFrames++; statBytes += len
                val now = System.currentTimeMillis()
                if (now - statT0 >= 1000) {
                    if (Diag.VERBOSE) Log.i(TAG, "USB rx: ${statFrames} frames/s, ${statBytes / 1024} KB/s")
                    statFrames = 0; statBytes = 0; statT0 = now
                }
            }
        } catch (e: Exception) {
            if (running) {
                Log.e(TAG, "USB 受信エラー", e)
                onError(e.message ?: "接続エラー")
            }
        }
    }

    companion object {
        private const val TAG = "DisproidReceiver"
        /** Mac の `adb reverse localabstract:disproid tcp:27184` と一致させる abstract socket 名。 */
        private const val ABSTRACT_NAME = "disproid"
        /** 1 アクセスユニット長の上限(32MB)。これを超える長さはストリーム破損とみなす。 */
        private const val MAX_AU_BYTES = 32 * 1024 * 1024
        /** 読み取りタイムアウト(ms)。この時間データが来なければ詰まり/USB切断とみなし再接続する。
         *  Mac 側が App Nap 抑止＋キープアライブで送信を維持するので誤発火しにくい。
         *  固まり検知を速くするため短めにする。 */
        private const val READ_TIMEOUT_MS = 5000
    }
}
