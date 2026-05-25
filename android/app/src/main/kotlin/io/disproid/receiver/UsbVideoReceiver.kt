package io.disproid.receiver

import android.util.Log
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import kotlin.concurrent.thread

/**
 * USB(adb reverse) 経由で Mac ヘルパーから映像を受信する。
 *
 * Mac ヘルパーが `adb reverse tcp:27184 tcp:27184` を設定済みなので、
 * 端末の localhost:27184 へ接続すると Mac の FrameServer に届く。
 *
 * プロトコル（FrameServer.swift と一致）:
 *   ヘッダ(14B): "DPRD" + version(1) + codec(1: 0=H264,1=H265) + width(4,BE) + height(4,BE)
 *   以降くり返し: length(4,BE) + Annex-B アクセスユニット
 */
class UsbVideoReceiver(
    private val sink: VideoSink,
    private val onFormat: (Int, Int) -> Unit,
    private val onError: (String) -> Unit,
    private val host: String = "127.0.0.1",
    private val port: Int = 27184,
) {
    @Volatile private var running = false
    private var socket: Socket? = null
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
            val s = Socket()
            s.connect(InetSocketAddress(host, port), 5000)
            s.tcpNoDelay = true
            socket = s
            val input = DataInputStream(s.getInputStream().buffered(1 shl 16))

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
                if (len <= 0) continue
                if (len > work.size) work = ByteArray(len)
                input.readFully(work, 0, len)
                sink.onVideoFrame(ByteBuffer.wrap(work, 0, len), len, ptsUs)
                ptsUs += 16_666 // 約60fps 相当の擬似 pts

                statFrames++; statBytes += len
                val now = System.currentTimeMillis()
                if (now - statT0 >= 1000) {
                    Log.i(TAG, "USB rx: ${statFrames} frames/s, ${statBytes / 1024} KB/s")
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
    }
}
