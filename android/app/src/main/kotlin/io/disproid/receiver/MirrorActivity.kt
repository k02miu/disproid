package io.disproid.receiver

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import com.google.android.material.button.MaterialButton

/**
 * ミラーリング映像を全画面表示する Activity。
 *
 * アスペクト比対応: ソース(例 1920x1080=16:9)をタブレット画面(例 16:10)に歪ませず表示するため、
 * SurfaceView を映像のアスペクト比に合わせて中央に letterbox/pillarbox 配置する（余白は黒）。
 */
class MirrorActivity : Activity(), SurfaceHolder.Callback {

    private val decoder = H264Decoder()
    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var connectingOverlay: View
    private lateinit var controlsOverlay: View

    private val uiHandler = Handler(Looper.getMainLooper())
    private val hideControlsRunnable = Runnable { hideControls() }

    /** true: USB(adb) 受信モード / false: AirPlay 受信モード */
    private var usbMode = false
    private var usbReceiver: UsbVideoReceiver? = null

    @Volatile private var videoW = 1920
    @Volatile private var videoH = 1080

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        usbMode = intent.getBooleanExtra(EXTRA_USB, false)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surfaceView = SurfaceView(this)
        root.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER
            )
        )
        connectingOverlay = buildConnectingOverlay()
        root.addView(
            connectingOverlay,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        // 操作オーバーレイ（タップで表示、停止ボタン）
        controlsOverlay = buildControlsOverlay()
        controlsOverlay.visibility = View.GONE
        root.addView(
            controlsOverlay,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        // 画面タップで操作オーバーレイを表示
        root.isClickable = true
        root.setOnClickListener { showControls() }

        setContentView(root)
        surfaceView.holder.addCallback(this)

        // 最初のフレームが描画されたら接続待ち表示を消す
        decoder.onFirstFrame = {
            runOnUiThread { connectingOverlay.visibility = View.GONE }
        }

        hideSystemUi()

        // 初期サイズ（既知のソース解像度）でアスペクト適用
        if (!usbMode) {
            videoW = NativeBridge.sourceWidth
            videoH = NativeBridge.sourceHeight
        }
        root.post { applyAspect() }

        if (!usbMode) {
            // AirPlay: 映像サイズ通知でアスペクト比を更新
            NativeBridge.videoSizeListener = { w, h ->
                if (w > 0 && h > 0 && (w != videoW || h != videoH)) {
                    videoW = w
                    videoH = h
                    applyAspect()
                }
            }
            // ミラー終了(Mac 切断)で自動的に閉じ、MainActivity に戻る
            NativeBridge.mirrorUiListener = { running ->
                if (!running && !isFinishing) {
                    Log.i(TAG, "ミラー終了を検知 → MirrorActivity を閉じる")
                    finish()
                }
            }
        }
    }

    /** USB 受信を開始する（停滞検知時/エラー時の再接続でも使う）。 */
    private fun startUsbReceiver() {
        if (isFinishing) return
        usbReceiver?.stop()
        decoder.requestFlush()  // 前接続の状態を持ち越さない（再接続直後の誤停滞検知を防ぐ）
        // 再接続中は接続待ち表示を再表示
        connectingOverlay.visibility = View.VISIBLE
        val (dw, dh) = deviceLandscapeSize()
        val receiver = UsbVideoReceiver(
            sink = decoder,
            onFormat = { w, h -> onUsbFormat(w, h) },
            deviceWidth = dw,
            deviceHeight = dh,
            onError = { msg ->
                runOnUiThread {
                    if (!isFinishing) {
                        // 接続が切れた時は Activity を閉じず、短い間隔で自動再接続。
                        // adb forward の再確立を待つだけなので間隔は短くてよい（復帰高速化）。
                        Log.w(TAG, "USB 受信エラー: $msg → 再接続")
                        uiHandler.postDelayed({ if (!isFinishing) startUsbReceiver() }, RECONNECT_DELAY_MS)
                    }
                }
            }
        )
        usbReceiver = receiver
        receiver.start()
    }

    /** タブレットの実画面解像度を landscape（長辺=幅）で返す。 */
    private fun deviceLandscapeSize(): Pair<Int, Int> {
        var w = 1920
        var h = 1080
        try {
            val wm = getSystemService(WINDOW_SERVICE) as WindowManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val b = wm.currentWindowMetrics.bounds
                w = b.width(); h = b.height()
            } else {
                @Suppress("DEPRECATION")
                val dm = resources.displayMetrics
                w = dm.widthPixels; h = dm.heightPixels
            }
        } catch (_: Throwable) {}
        return Pair(maxOf(w, h), minOf(w, h))
    }

    /** USB 受信時の映像サイズ通知でアスペクト比を更新（メインスレッドへ）。 */
    private fun onUsbFormat(w: Int, h: Int) {
        runOnUiThread {
            if (w > 0 && h > 0) {
                videoW = w
                videoH = h
                applyAspect()
            }
        }
    }

    /** 接続待ち（最初のフレームが来るまで）の中央オーバーレイ。 */
    private fun buildConnectingOverlay(): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            // 背景は塗らない。再接続時に直前のフレームを覆って暗転・チカチカするのを防ぎ、
            // 画面中央にスピナーだけを重ねる（初回は root が黒なので黒地に表示される）。
        }
        val spinner = ProgressBar(this).apply {
            isIndeterminate = true
        }
        container.addView(
            spinner,
            LinearLayout.LayoutParams(120, 120)
        )
        return container
    }

    /** 画面タップで出る操作オーバーレイ（半透明スクリム＋停止ボタン）。 */
    private fun buildControlsOverlay(): View {
        val scrim = FrameLayout(this).apply {
            setBackgroundColor(0x99000000.toInt())
            isClickable = true
            setOnClickListener { hideControls() } // スクリム外側タップで閉じる
        }
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            isClickable = true // パネル内タップはスクリムへ伝播させない
        }
        val title = TextView(this).apply {
            text = "ミラーリング中"
            setTextColor(Color.WHITE)
            textSize = 20f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 40)
        }
        val stopButton = MaterialButton(this).apply {
            text = getString(R.string.action_stop)
            setOnClickListener { stopCasting() }
        }
        panel.addView(title)
        panel.addView(
            stopButton,
            LinearLayout.LayoutParams(
                (220 * resources.displayMetrics.density).toInt(),
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )
        scrim.addView(
            panel,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )
        return scrim
    }

    private fun showControls() {
        controlsOverlay.visibility = View.VISIBLE
        uiHandler.removeCallbacks(hideControlsRunnable)
        uiHandler.postDelayed(hideControlsRunnable, 3500) // 数秒で自動的に消える
    }

    private fun hideControls() {
        uiHandler.removeCallbacks(hideControlsRunnable)
        controlsOverlay.visibility = View.GONE
        hideSystemUi()
    }

    /** ミラーリングを停止して画面を閉じる。 */
    private fun stopCasting() {
        Log.i(TAG, "ユーザー操作でミラーリング停止")
        if (usbMode) {
            usbReceiver?.stop()
        } else {
            stopService(Intent(this, AdvertiseService::class.java))
        }
        finish()
    }

    /** SurfaceView を映像アスペクト比に合わせて中央配置（歪み防止）。 */
    private fun applyAspect() {
        val cw = root.width
        val ch = root.height
        if (cw <= 0 || ch <= 0 || videoW <= 0 || videoH <= 0) return
        val videoAspect = videoW.toFloat() / videoH.toFloat()
        val containerAspect = cw.toFloat() / ch.toFloat()
        val (sw, sh) = if (containerAspect > videoAspect) {
            // 画面が映像より横長 → 高さ基準（左右に黒帯=pillarbox）
            Pair((ch * videoAspect).toInt(), ch)
        } else {
            // 画面が映像より縦長 → 幅基準（上下に黒帯=letterbox）
            Pair(cw, (cw / videoAspect).toInt())
        }
        val lp = surfaceView.layoutParams as FrameLayout.LayoutParams
        if (lp.width != sw || lp.height != sh) {
            lp.width = sw
            lp.height = sh
            lp.gravity = Gravity.CENTER
            surfaceView.layoutParams = lp
            Log.i(TAG, "アスペクト適用: video=${videoW}x${videoH} surface=${sw}x${sh} (画面 ${cw}x${ch})")
        }
    }

    override fun onResume() {
        super.onResume()
        hideSystemUi()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "Surface 準備完了。描画先を登録 (usbMode=$usbMode)")
        decoder.onVideoFormat(videoW, videoH)
        decoder.setSurface(holder.surface)
        if (usbMode) {
            // 停滞時はデコーダが自己リセットし Mac の定期 IDR で復帰する（再接続はしない）。
            // 接続が切れた時のみ UsbVideoReceiver.onError 経由で startUsbReceiver する。
            startUsbReceiver()
        } else {
            NativeBridge.frameSink = decoder
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // SurfaceView のサイズ変更（アスペクト適用）。同一 Surface のためデコーダ再登録は不要。
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "Surface 破棄。描画先を解除")
        usbReceiver?.stop()
        usbReceiver = null
        NativeBridge.frameSink = null
        decoder.setSurface(null)
    }

    override fun onDestroy() {
        uiHandler.removeCallbacks(hideControlsRunnable)
        usbReceiver?.stop()
        usbReceiver = null
        decoder.onFirstFrame = null
        NativeBridge.mirrorUiListener = null
        NativeBridge.videoSizeListener = null
        if (NativeBridge.frameSink === decoder) {
            NativeBridge.frameSink = null
        }
        decoder.setSurface(null)
        super.onDestroy()
    }

    private fun hideSystemUi() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            val controller = try { window.insetsController } catch (e: Exception) { null }
            controller?.let {
                it.hide(android.view.WindowInsets.Type.systemBars())
                it.systemBarsBehavior =
                    android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                )
        }
    }

    companion object {
        private const val TAG = "DisproidReceiver"
        /** USB(adb) 受信モードで起動する Intent extra。 */
        const val EXTRA_USB = "io.disproid.receiver.USB_MODE"
        /** 切断検知から再接続を試みるまでの待ち(ms)。短いほど復帰が速い。 */
        private const val RECONNECT_DELAY_MS = 150L
    }
}
