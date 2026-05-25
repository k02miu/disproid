package io.disproid.receiver

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.os.Build
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.MaterialAutoCompleteTextView
import android.view.View

/**
 * 最小 UI（Material 3）。公開サービスの開始/停止、解像度選択、状態表示。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var statusText: android.widget.TextView
    private lateinit var statusDot: View
    private lateinit var startButton: MaterialButton
    private lateinit var stopButton: MaterialButton
    private lateinit var resolutionDropdown: MaterialAutoCompleteTextView

    override fun onCreate(savedInstanceState: Bundle?) {
        // 起動スプラッシュ（super.onCreate より前に呼ぶ）
        installSplashScreen()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        setSupportActionBar(findViewById<MaterialToolbar>(R.id.toolbar))

        statusText = findViewById(R.id.statusText)
        statusDot = findViewById(R.id.statusDot)
        startButton = findViewById(R.id.startButton)
        stopButton = findViewById(R.id.stopButton)
        resolutionDropdown = findViewById(R.id.resolutionDropdown)

        setupResolutionDropdown()

        startButton.setOnClickListener { startAdvertising() }
        stopButton.setOnClickListener { stopAdvertising() }

        maybeRequestNotificationPermission()
    }

    private fun setupResolutionDropdown() {
        val labels = ResolutionOptions.list.map { it.label }.toTypedArray()
        resolutionDropdown.setSimpleItems(labels)
        val savedIdx = ResolutionOptions.savedIndex(this)
        resolutionDropdown.setText(labels[savedIdx], false)
        resolutionDropdown.setOnItemClickListener { _, _, position, _ ->
            ResolutionOptions.save(this, position)
            if (StatusBus.running) {
                statusText.text = "解像度は「停止→公開を開始」で反映されます"
            }
        }
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
        val dotColor = if (running) R.color.status_active else R.color.status_idle
        statusDot.backgroundTintList =
            ColorStateList.valueOf(ContextCompat.getColor(this, dotColor))
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
