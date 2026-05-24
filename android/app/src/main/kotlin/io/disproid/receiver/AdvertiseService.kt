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
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * フォアグラウンドサービス。画面オフでも mDNS 広告を継続する。
 *
 * 役割（Phase A）:
 *  1. TCP サーバを listen（接続が来てもログのみ。プロトコル処理は次フェーズ）
 *  2. NsdManager で `_airplay._tcp` を上記ポートで広告し、TXT に Apple TV 識別属性を載せる
 *
 * ペアリング・暗号・映像は一切扱わない。
 */
class AdvertiseService : Service() {

    private var serverSocket: ServerSocket? = null
    private var serverThread: Thread? = null
    @Volatile private var acceptRunning = false

    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startAsForeground()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (acceptRunning) {
            // 二重起動を無視
            return START_STICKY
        }
        try {
            val port = startTcpServer()
            registerService(port)
        } catch (e: Exception) {
            Log.e(TAG, "起動に失敗", e)
            StatusBus.update(running = false, status = "起動失敗: ${e.message}")
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        unregisterService()
        stopTcpServer()
        StatusBus.update(running = false, status = "停止中")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    // ---- TCP スタブサーバ ----

    /** TCP サーバを起動し、listen しているポート番号を返す。 */
    private fun startTcpServer(): Int {
        // 慣例の AirPlay ポート 7000 を試し、ダメなら ephemeral ポートに委ねる。
        val socket = try {
            ServerSocket(AIRPLAY_DEFAULT_PORT)
        } catch (e: IOException) {
            Log.w(TAG, "ポート $AIRPLAY_DEFAULT_PORT を確保できず ephemeral ポートを使用", e)
            ServerSocket(0)
        }
        serverSocket = socket
        acceptRunning = true

        serverThread = thread(name = "disproid-tcp-accept") {
            Log.i(TAG, "TCP listen 開始 port=${socket.localPort}")
            while (acceptRunning && !socket.isClosed) {
                val client: Socket = try {
                    socket.accept()
                } catch (e: IOException) {
                    if (acceptRunning) Log.w(TAG, "accept エラー", e)
                    break
                }
                // Phase A: 何もしない。接続元をログに残して即クローズ（スタブ）。
                Log.i(TAG, "接続を受信: ${client.inetAddress?.hostAddress}:${client.port}（スタブのため何もしない）")
                try {
                    client.close()
                } catch (_: IOException) {
                }
            }
            Log.i(TAG, "TCP accept ループ終了")
        }
        return socket.localPort
    }

    private fun stopTcpServer() {
        acceptRunning = false
        try {
            serverSocket?.close()
        } catch (_: IOException) {
        }
        serverSocket = null
        serverThread = null
    }

    // ---- mDNS (NsdManager) ----

    private fun registerService(port: Int) {
        val identity = DeviceIdentity.load(this)
        val info = NsdServiceInfo().apply {
            serviceName = getString(R.string.service_display_name)
            serviceType = AirPlayTxtRecord.SERVICE_TYPE
            setPort(port)
            // TXT レコード（Apple TV 識別属性）
            AirPlayTxtRecord.build(identity).forEach { (k, v) ->
                setAttribute(k, v)
            }
        }

        val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager = manager

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                val msg = "広告中: ${serviceInfo.serviceName} (${AirPlayTxtRecord.SERVICE_TYPE}) " +
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
        StatusBus.update(running = true, status = "広告登録中… port=$port")
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
                "AirPlay 広告",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Apple TV として mDNS 広告を継続中" }
            nm.createNotificationChannel(channel)
        }

        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Disproid Receiver")
            .setContentText("Apple TV として広告中")
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
        // AirPlay の慣例ポート。確保できなければ ephemeral にフォールバック。
        private const val AIRPLAY_DEFAULT_PORT = 7000
    }
}
