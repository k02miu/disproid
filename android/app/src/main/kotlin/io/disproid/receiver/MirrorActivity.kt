package io.disproid.receiver

import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Color
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
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
    /** 画面サイズ変化(回転・起動時settle)を debounce して Mac へ再通知する。 */
    private val renotifyRunnable = Runnable { renotifyIfSizeChanged() }
    /** AOA 受信の再接続リトライ。 */
    private val aoaRetryRunnable = Runnable { if (!isFinishing && aoaMode) startAoaReceiver() }

    /** true: USB 受信モード(adb or AOA) / false: AirPlay 受信モード */
    private var usbMode = false
    private var usbReceiver: UsbVideoReceiver? = null

    /** true: AOA(直接USB) 受信。accessory intent から起動された場合。 */
    private var aoaMode = false
    private var aoaAccessory: UsbAccessory? = null
    private var aoaReceiver: AoaVideoReceiver? = null

    @Volatile private var videoW = 1920
    @Volatile private var videoH = 1080

    /** 直近に Mac へ通知した解像度。向き変更を検知して再通知するのに使う。 */
    private var lastNotifiedSize: Pair<Int, Int>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // AOA: accessory intent から起動されたか判定（USB_ACCESSORY_ATTACHED または EXTRA_ACCESSORY）。
        aoaAccessory = intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        aoaMode = aoaAccessory != null || intent.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED
        usbMode = aoaMode || intent.getBooleanExtra(EXTRA_USB, false)
        if (usbMode) {
            // USB モードはシステムの向き設定に追従する（自動回転 ON ならセンサー、
            // 縦/横に固定していればその向き）。縦固定なら縦の拡張ディスプレイになる。
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        }
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

        // 実画面サイズの変化(回転・起動時の向き確定・マルチウィンドウ等)を監視する。
        // surfaceCreated 時の一度きりの読み取りだと、起動直後に向きが確定する前(横)を
        // 拾って Mac に横の仮想ディスプレイを作らせてしまう。レイアウト確定値を常時見て、
        // サイズが変われば再レターボックス＋Mac へ再通知する(縦↔横の追従)。
        root.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, oR, ob ->
            if ((r - l) != (oR - ol) || (b - t) != (ob - ot)) {
                applyAspect()
                scheduleRenotify()
            }
        }

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

    /** AOA: 端末が再 attach（Mac が再遷移）すると新しい accessory intent が届く。受信を再開する。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val acc = intent.getParcelableExtra<UsbAccessory>(UsbManager.EXTRA_ACCESSORY)
        if (acc != null) {
            Log.i(TAG, "新しい accessory 接続を検知 → AOA 受信を再開")
            aoaAccessory = acc
            aoaMode = true
            uiHandler.removeCallbacks(aoaRetryRunnable)
            startAoaReceiver()
        }
    }

    /** USB 受信を開始する（停滞検知時/エラー時の再接続でも使う）。 */
    private fun startUsbReceiver() {
        if (isFinishing) return
        usbReceiver?.stop()
        decoder.requestFlush()  // 前接続の状態を持ち越さない（再接続直後の誤停滞検知を防ぐ）
        // 再接続中は接続待ち表示を再表示
        connectingOverlay.visibility = View.VISIBLE
        val (dw, dh) = deviceCurrentSize()
        lastNotifiedSize = Pair(dw, dh)
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

    /** AOA(直接USB) 受信を開始/再開する。accessory を開いて AoaVideoReceiver を回す。
     *  切断時は画面を閉じず、接続待ち表示にして再接続をリトライする。 */
    private fun startAoaReceiver() {
        if (isFinishing) return
        aoaReceiver?.stop()
        decoder.requestFlush()
        connectingOverlay.visibility = View.VISIBLE
        val mgr = getSystemService(USB_SERVICE) as UsbManager
        // accessory が抜けていると accessoryList が空。再 attach（onNewIntent）か復帰までリトライ。
        val accessory = aoaAccessory ?: mgr.accessoryList?.firstOrNull()
        if (accessory == null) {
            Log.w(TAG, "AOA accessory 未検出 → 再試行待ち")
            scheduleAoaRetry(); return
        }
        aoaAccessory = accessory
        // openAccessory は accessory が抜けていると null ではなく例外を投げる
        // (IllegalArgumentException: no accessory attached)。catch して再試行する。
        val pfd = try {
            mgr.openAccessory(accessory)
        } catch (e: Exception) {
            Log.w(TAG, "openAccessory 例外: ${e.message} → 再試行")
            aoaAccessory = null  // スタブを破棄して次回は accessoryList から取り直す
            null
        }
        if (pfd == null) {
            Log.w(TAG, "openAccessory 失敗 → 再試行")
            scheduleAoaRetry(); return
        }
        val (dw, dh) = deviceCurrentSize()
        lastNotifiedSize = Pair(dw, dh)
        val receiver = AoaVideoReceiver(
            fd = pfd,
            sink = decoder,
            onFormat = { w, h -> onUsbFormat(w, h) },
            deviceWidth = dw,
            deviceHeight = dh,
            onError = { msg ->
                runOnUiThread {
                    if (!isFinishing) {
                        Log.w(TAG, "AOA 受信エラー: $msg → 再接続")
                        connectingOverlay.visibility = View.VISIBLE
                        scheduleAoaRetry()
                    }
                }
            }
        )
        aoaReceiver = receiver
        receiver.start()
    }

    /** AOA 受信の再接続を debounce して再試行する。 */
    private fun scheduleAoaRetry() {
        if (isFinishing || !aoaMode) return
        uiHandler.removeCallbacks(aoaRetryRunnable)
        uiHandler.postDelayed(aoaRetryRunnable, AOA_RETRY_MS)
    }

    /** 画面サイズ変化を debounce して再通知する（回転中の連続レイアウトを1回に畳む）。 */
    private fun scheduleRenotify() {
        // TODO(AOA): AOA は現状ハンドシェイク1回のみのため回転リビルド未対応。
        // adb 経路(usbMode かつ非AOA)でのみ回転に追従して再通知する。
        if (!usbMode || aoaMode) return
        uiHandler.removeCallbacks(renotifyRunnable)
        uiHandler.postDelayed(renotifyRunnable, RENOTIFY_DEBOUNCE_MS)
    }

    /** 現在の実画面サイズが前回通知と変わっていれば、再接続して Mac へ通知する。 */
    private fun renotifyIfSizeChanged() {
        if (!usbMode || isFinishing) return
        val size = deviceCurrentSize()
        if (size != lastNotifiedSize) {
            Log.i(TAG, "画面サイズ変化: ${size.first}x${size.second} → 再接続して解像度を通知")
            startUsbReceiver()
        }
    }

    /** タブレットの現在の向きの実画面解像度を返す（縦持ちなら w<h、横持ちなら w>h）。 */
    private fun deviceCurrentSize(): Pair<Int, Int> {
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
        return Pair(w, h)  // 向きそのまま（Mac はこの比率で仮想ディスプレイを作る）
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
            aoaReceiver?.stop()
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

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        hideSystemUi()
        // 向きが変わったら新しい解像度を Mac に通知し、縦/横の仮想ディスプレイに作り直してもらう。
        // 実際の再通知はレイアウト確定後の値で行うため debounce 経由にする
        // (この時点では currentWindowMetrics が更新前のことがある)。
        scheduleRenotify()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "Surface 準備完了。描画先を登録 (usbMode=$usbMode)")
        decoder.onVideoFormat(videoW, videoH)
        decoder.setSurface(holder.surface)
        if (aoaMode) {
            startAoaReceiver()
        } else if (usbMode) {
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
        aoaReceiver?.stop()
        aoaReceiver = null
        NativeBridge.frameSink = null
        decoder.setSurface(null)
    }

    override fun onDestroy() {
        uiHandler.removeCallbacks(hideControlsRunnable)
        uiHandler.removeCallbacks(renotifyRunnable)
        uiHandler.removeCallbacks(aoaRetryRunnable)
        usbReceiver?.stop()
        usbReceiver = null
        aoaReceiver?.stop()
        aoaReceiver = null
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
        /** 画面サイズ変化の再通知 debounce(ms)。回転アニメ中の連続レイアウトを1回に畳む。 */
        private const val RENOTIFY_DEBOUNCE_MS = 250L
        /** AOA 受信の再接続リトライ間隔(ms)。抜き差し/再遷移を待つので少し長め。 */
        private const val AOA_RETRY_MS = 700L
    }
}
