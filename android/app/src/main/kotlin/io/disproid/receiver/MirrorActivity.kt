package io.disproid.receiver

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout

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

    @Volatile private var videoW = 1920
    @Volatile private var videoH = 1080

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

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
        setContentView(root)
        surfaceView.holder.addCallback(this)

        hideSystemUi()

        // 初期サイズ（既知のソース解像度）でアスペクト適用
        videoW = NativeBridge.sourceWidth
        videoH = NativeBridge.sourceHeight
        root.post { applyAspect() }

        // 映像サイズ通知でアスペクト比を更新
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
        Log.i(TAG, "Surface 準備完了。描画先を登録")
        decoder.onVideoFormat(videoW, videoH)
        decoder.setSurface(holder.surface)
        NativeBridge.frameSink = decoder
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // SurfaceView のサイズ変更（アスペクト適用）。同一 Surface のためデコーダ再登録は不要。
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "Surface 破棄。描画先を解除")
        NativeBridge.frameSink = null
        decoder.setSurface(null)
    }

    override fun onDestroy() {
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
    }
}
