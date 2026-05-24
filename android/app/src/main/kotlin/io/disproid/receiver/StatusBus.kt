package io.disproid.receiver

import android.os.Handler
import android.os.Looper

/**
 * サービス → Activity の状態通知用の極簡易バス（同一プロセス前提）。
 * 外部依存（LiveData 等）を避けるため、メインスレッドへ post するだけの薄い仕組み。
 */
object StatusBus {
    @Volatile var running: Boolean = false
        private set

    @Volatile var lastStatus: String = "停止中"
        private set

    private val mainHandler = Handler(Looper.getMainLooper())
    private var listener: ((running: Boolean, status: String) -> Unit)? = null

    fun setListener(l: ((running: Boolean, status: String) -> Unit)?) {
        listener = l
        // 登録直後に現在値を一度通知
        l?.let { cb -> mainHandler.post { cb(running, lastStatus) } }
    }

    fun update(running: Boolean, status: String) {
        this.running = running
        this.lastStatus = status
        mainHandler.post { listener?.invoke(running, status) }
    }
}
