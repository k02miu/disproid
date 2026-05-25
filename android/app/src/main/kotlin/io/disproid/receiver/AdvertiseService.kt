package io.disproid.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
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
        if (nativeStarted) {
            return START_STICKY
        }
        try {
            val identity = DeviceIdentity.load(this)
            val keyfile = File(filesDir, "airplay_ed25519.key").absolutePath
            val name = getString(R.string.service_display_name)

            // ネイティブ raop サーバ起動 → listen ポート取得
            val port = NativeAirPlay.nativeStart(identity.deviceId, name, keyfile)
            if (port < 0) {
                throw IllegalStateException("nativeStart 失敗 (code=$port)")
            }
            nativeStarted = true
            val pk = NativeAirPlay.nativeGetPublicKey()
            Log.i(TAG, "ネイティブ raop 起動 port=$port pk=$pk")

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
                NativeAirPlay.nativeStop()
            } catch (e: Throwable) {
                Log.w(TAG, "nativeStop 失敗", e)
            }
            nativeStarted = false
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

        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Disproid Receiver")
            .setContentText("Apple TV として公開中")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
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
    }
}
