package io.disproid.receiver

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager

/**
 * ミラーリング映像を全画面表示する Activity。
 * SurfaceView の Surface が準備できたら H264Decoder を [NativeBridge] の描画先に登録する。
 */
class MirrorActivity : Activity(), SurfaceHolder.Callback {

    private val decoder = H264Decoder()
    private lateinit var surfaceView: SurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 画面オフ防止
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // setContentView より前に insetsController へ触ると DecorView 未生成で NPE になるため、
        // 必ず setContentView 後に hideSystemUi() を呼ぶ。
        surfaceView = SurfaceView(this)
        setContentView(surfaceView)
        surfaceView.holder.addCallback(this)

        hideSystemUi()

        // ミラー終了(Mac 切断)で自動的に閉じ、MainActivity に戻る
        NativeBridge.mirrorUiListener = { running ->
            if (!running && !isFinishing) {
                Log.i(TAG, "ミラー終了を検知 → MirrorActivity を閉じる")
                finish()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        hideSystemUi()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "Surface 準備完了。描画先を登録")
        decoder.onVideoFormat(NativeBridge.sourceWidth, NativeBridge.sourceHeight)
        decoder.setSurface(holder.surface)
        NativeBridge.frameSink = decoder
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // Surface サイズ変更は MediaCodec 側が出力フォーマット変更で吸収する
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "Surface 破棄。描画先を解除")
        NativeBridge.frameSink = null
        decoder.setSurface(null)
    }

    override fun onDestroy() {
        NativeBridge.mirrorUiListener = null
        if (NativeBridge.frameSink === decoder) {
            NativeBridge.frameSink = null
        }
        decoder.setSurface(null)
        super.onDestroy()
    }

    private fun hideSystemUi() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            // DecorView 未生成だと getInsetsController() が NPE を投げるため保護する
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
