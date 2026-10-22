package com.pecuariabulltrade.manga

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.webkit.WebViewAssetLoader
import org.json.JSONObject

class MainActivity : AppCompatActivity(), ScaleLink.Listener {

    private lateinit var web: WebView
    private lateinit var link: ScaleLink
    private var tone: ToneGenerator? = null

    private val askBluetooth = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        js("window.Manga && Manga.onPermission(${ok})")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        link = ScaleLink(this, this)
        tone = try { ToneGenerator(AudioManager.STREAM_MUSIC, 100) } catch (_: Exception) { null }

        web = WebView(this)
        setContentView(web)
        with(web.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mediaPlaybackRequiresUserGesture = false
            builtInZoomControls = false
            textZoom = 100
        }
        val loader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                loader.shouldInterceptRequest(request.url)
        }
        web.addJavascriptInterface(Bridge(), "Android")
        web.loadUrl("https://appassets.androidplatform.net/assets/www/index.html")
    }

    override fun onResume() {
        super.onResume()
        js("window.Manga && Manga.onResume()")
    }

    override fun onDestroy() {
        link.disconnect()
        tone?.release()
        super.onDestroy()
    }

    private fun js(code: String) {
        runOnUiThread { web.evaluateJavascript(code, null) }
    }

    private fun jsStr(s: String): String = JSONObject.quote(s)

    // ---- ScaleLink.Listener ----
    override fun onLine(line: String) = js("window.Manga && Manga.onLine(${jsStr(line)})")
    override fun onStatus(status: JSONObject) = js("window.Manga && Manga.onStatus(${status})")
    override fun onLog(text: String) = js("window.Manga && Manga.onLog(${jsStr(text)})")

    private fun hasBtPermission(): Boolean =
        Build.VERSION.SDK_INT < 31 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    inner class Bridge {
        @JavascriptInterface fun version(): String = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
        } catch (_: Exception) { "?" }

        @JavascriptInterface fun deviceName(): String =
            (Build.MANUFACTURER + " " + Build.MODEL).trim()

        @JavascriptInterface fun online(): Boolean {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
            return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }

        @JavascriptInterface fun hasBluetoothPermission(): Boolean = hasBtPermission()

        @JavascriptInterface fun requestBluetoothPermission() {
            if (hasBtPermission()) { js("window.Manga && Manga.onPermission(true)"); return }
            runOnUiThread { askBluetooth.launch(Manifest.permission.BLUETOOTH_CONNECT) }
        }

        @JavascriptInterface fun bluetoothEnabled(): Boolean = link.bluetoothEnabled()
        @JavascriptInterface fun pairedDevices(): String = if (hasBtPermission()) link.pairedDevices() else "[]"
        @JavascriptInterface fun connectBluetooth(address: String) { if (hasBtPermission()) link.connectBluetooth(address) }
        @JavascriptInterface fun usbDevices(): String = link.usbDevices()
        @JavascriptInterface fun setUsbBaud(baud: Int) = link.setUsbBaud(baud)
        @JavascriptInterface fun connectUsb() = link.connectUsb()
        @JavascriptInterface fun disconnect() = link.disconnect()
        @JavascriptInterface fun reconnect() = link.reconnectLast()
        @JavascriptInterface fun status(): String = link.status().toString()

        @JavascriptInterface fun openBluetoothSettings() {
            runOnUiThread { try { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) } catch (_: Exception) {} }
        }

        @Suppress("DEPRECATION")
        @JavascriptInterface fun vibrate(ms: Int) {
            try {
                val v: Vibrator = if (Build.VERSION.SDK_INT >= 31)
                    (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
                else (getSystemService(Context.VIBRATOR_SERVICE) as Vibrator)
                v.vibrate(VibrationEffect.createOneShot(ms.toLong(), VibrationEffect.DEFAULT_AMPLITUDE))
            } catch (_: Exception) {}
        }

        /** kind: "verde" (un beep corto), "amarillo" (dos beeps), "rojo" (beep largo grave) */
        @JavascriptInterface fun beep(kind: String) {
            val t = tone ?: return
            Thread {
                try {
                    when (kind) {
                        "rojo" -> t.startTone(ToneGenerator.TONE_CDMA_ABBR_ALERT, 700)
                        "amarillo" -> { t.startTone(ToneGenerator.TONE_PROP_BEEP, 150); Thread.sleep(250); t.startTone(ToneGenerator.TONE_PROP_BEEP, 150) }
                        else -> t.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
                    }
                } catch (_: Exception) {}
            }.start()
        }
    }
}
