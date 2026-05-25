package io.disproid.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File

/**
 * フォアグラウンドサービス。画面オフでも mDNS 公開を継続する。
 *
 * Phase B:
 *  1. ネイティブ AirPlay コア（UxPlay 由来 / libdisproid.so）の raop サーバを起動。
 *     接続が来ると RTSP/ペアリングのやり取りが行われ、logcat(TAG=DisproidNative)に出る。
 *  2. NsdManager で `_airplay._tcp` を raop の listen ポートで公開。TXT の pk は
 *     raop が生成した ed25519 公開鍵に揃える。
 *
 * 映像・音声のデコード/表示は Phase C（video_process/audio_process は現状ログのみ）。
 */
class AdvertiseService : Service() {

    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    @Volatile private var nativeStarted = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startAsForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Log.i(TAG, "停止アクション受信")
            stopSelf()
            return START_NOT_STICKY
        }
        if (nativeStarted) {
            return START_STICKY
        }
        try {
            val identity = DeviceIdentity.load(this)
            val keyfile = File(filesDir, "airplay_ed25519.key").absolutePath
            val name = getString(R.string.service_display_name)

            // タブレット実ディスプレイの解像度・リフレッシュレートを /info で Mac に報告し、
            // タブレットのアスペクト比に合った映像を送らせる。
            val (dispW, dispH, dispHz) = displayInfo()
            Log.i(TAG, "タブレットディスプレイ: ${dispW}x${dispH} @${dispHz}Hz")

            // ネイティブ raop サーバ起動 → listen ポート取得
            val port = NativeAirPlay.nativeStart(identity.deviceId, name, keyfile, dispW, dispH, dispHz)
            if (port < 0) {
                throw IllegalStateException("nativeStart 失敗 (code=$port)")
            }
            nativeStarted = true
            val pk = NativeAirPlay.nativeGetPublicKey()
            Log.i(TAG, "ネイティブ raop 起動 port=$port pk=$pk")

            // 映像フレームの受け取り先を登録し、ミラー開始時に全画面 Activity を起動する
            NativeAirPlay.nativeSetVideoSink(NativeBridge)
            NativeBridge.mirrorListener = { running ->
                if (running) launchMirror()
            }

            registerService(port, identity, pk)
        } catch (e: Throwable) {
            Log.e(TAG, "起動に失敗", e)
            StatusBus.update(running = false, status = "起動失敗: ${e.message}")
            stopNative()
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        unregisterService()
        stopNative()
        StatusBus.update(running = false, status = "停止中")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun stopNative() {
        if (nativeStarted) {
            try {
                NativeBridge.mirrorListener = null
                NativeAirPlay.nativeSetVideoSink(null)
                NativeAirPlay.nativeStop()
            } catch (e: Throwable) {
                Log.w(TAG, "nativeStop 失敗", e)
            }
            nativeStarted = false
        }
    }

    /** Mac に報告する解像度(landscape)とリフレッシュレートを返す。
     *  設定で固定解像度が選ばれていればそれを、「自動」ならタブレット実アスペクト比から算出。 */
    private fun displayInfo(): Triple<Int, Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        var w = 1920
        var h = 1080
        var hz = 60
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val b = wm.currentWindowMetrics.bounds
                w = b.width()
                h = b.height()
            } else {
                @Suppress("DEPRECATION")
                val dm = resources.displayMetrics
                w = dm.widthPixels
                h = dm.heightPixels
            }
            @Suppress("DEPRECATION")
            hz = wm.defaultDisplay.refreshRate.toInt().coerceIn(30, 240)
        } catch (e: Throwable) {
            Log.w(TAG, "ディスプレイ情報取得失敗、既定値を使用", e)
        }

        val opt = ResolutionOptions.saved(this)
        if (opt.width > 0 && opt.height > 0) {
            // 固定解像度を選択
            return Triple(opt.width, opt.height, hz)
        }
        // 自動: landscape の実アスペクト比を保ち、width=1920 基準へ正規化（偶数化）
        val pw = maxOf(w, h)
        val ph = minOf(w, h)
        val targetW = 1920
        val targetH = (targetW.toLong() * ph / pw).toInt().let { it - (it % 2) }
        return Triple(targetW, targetH, hz)
    }

    /** ミラー開始時に全画面 MirrorActivity を起動する（ベストエフォート）。
     *  バックグラウンド起動が制限される場合は、通知タップ（contentIntent）で開ける。 */
    private fun launchMirror() {
        try {
            val intent = Intent(this, MirrorActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            startActivity(intent)
        } catch (e: Throwable) {
            Log.w(TAG, "MirrorActivity 自動起動に失敗（通知から開いてください）", e)
        }
    }

    // ---- mDNS (NsdManager) ----

    private fun registerService(port: Int, identity: DeviceIdentity, pk: String) {
        val info = NsdServiceInfo().apply {
            serviceName = getString(R.string.service_display_name)
            serviceType = AirPlayTxtRecord.SERVICE_TYPE
            setPort(port)
            // TXT の pk は raop の公開鍵に揃える（GET /info と一致させる）
            AirPlayTxtRecord.build(identity, pkOverride = pk).forEach { (k, v) ->
                setAttribute(k, v)
            }
        }

        val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager = manager

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                val msg = "公開中: ${serviceInfo.serviceName} (${AirPlayTxtRecord.SERVICE_TYPE}) " +
                    "port=$port model=${AirPlayTxtRecord.MODEL}"
                Log.i(TAG, msg)
                StatusBus.update(running = true, status = msg)
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "mDNS 登録失敗 errorCode=$errorCode")
                StatusBus.update(running = false, status = "mDNS 登録失敗 (code=$errorCode)")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "mDNS 登録解除")
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "mDNS 登録解除失敗 errorCode=$errorCode")
            }
        }
        registrationListener = listener
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        StatusBus.update(running = true, status = "公開登録中… port=$port")
    }

    private fun unregisterService() {
        val manager = nsdManager
        val listener = registrationListener
        if (manager != null && listener != null) {
            try {
                manager.unregisterService(listener)
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "unregister 済み/未登録", e)
            }
        }
        registrationListener = null
        nsdManager = null
    }

    // ---- フォアグラウンド通知 ----

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "AirPlay 公開",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Apple TV として mDNS 公開を継続中" }
            nm.createNotificationChannel(channel)
        }

        // 通知タップで全画面ミラーを開ける（自動起動が制限された場合のフォールバック）
        val openMirror = PendingIntent.getActivity(
            this, 0,
            Intent(this, MirrorActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )

        // 通知の「停止」アクション（全画面表示中でも通知シェードから停止できる）
        val stopPending = PendingIntent.getService(
            this, 1,
            Intent(this, AdvertiseService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Disproid Receiver")
            .setContentText("Apple TV として公開中（タップでミラー表示）")
            .setSmallIcon(R.drawable.ic_stat_cast)
            .setContentIntent(openMirror)
            .addAction(Notification.Action.Builder(null, "停止", stopPending).build())
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    companion object {
        private const val TAG = "DisproidReceiver"
        private const val CHANNEL_ID = "disproid_advertise"
        private const val NOTIF_ID = 1
        const val ACTION_STOP = "io.disproid.receiver.action.STOP"
    }
}
