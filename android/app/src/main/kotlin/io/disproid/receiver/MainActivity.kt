package io.disproid.receiver

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.TextView

/**
 * 最小 UI。公開サービスの開始/停止と状態表示のみ。
 */
class MainActivity : Activity() {

    private lateinit var statusText: TextView
    private lateinit var startButton: Button
    private lateinit var stopButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.statusText)
        startButton = findViewById(R.id.startButton)
        stopButton = findViewById(R.id.stopButton)

        startButton.setOnClickListener { startAdvertising() }
        stopButton.setOnClickListener { stopAdvertising() }

        maybeRequestNotificationPermission()
    }

    override fun onResume() {
        super.onResume()
        StatusBus.setListener { running, status -> applyState(running, status) }
    }

    override fun onPause() {
        super.onPause()
        StatusBus.setListener(null)
    }

    private fun applyState(running: Boolean, status: String) {
        statusText.text = status
        startButton.isEnabled = !running
        stopButton.isEnabled = running
    }

    private fun startAdvertising() {
        val intent = Intent(this, AdvertiseService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopAdvertising() {
        stopService(Intent(this, AdvertiseService::class.java))
    }

    /** Android 13+ では FGS の常駐通知表示に POST_NOTIFICATIONS の実行時許可が要る。 */
    private fun maybeRequestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF)
            }
        }
    }

    companion object {
        private const val REQ_NOTIF = 100
    }
}
