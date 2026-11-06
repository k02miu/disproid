package io.disproid.receiver

import android.content.Intent
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity

/** Read bundled notices offline. External source links open in the user's browser. */
class LicensesActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "ライセンスとソース"
        setContentView(WebView(this).apply {
            settings.javaScriptEnabled = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val url = request.url
                    if (url.scheme == "https") {
                        startActivity(Intent(Intent.ACTION_VIEW, url))
                        return true
                    }
                    return !url.toString().startsWith("file:///android_asset/oss/")
                }
            }
            loadUrl("file:///android_asset/oss/index.html")
        })
    }
}
