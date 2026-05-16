package dev.suji.examples.android

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebView
import org.json.JSONObject

class MainActivity : Activity() {
    private lateinit var webView: WebView
    private val ui = Handler(Looper.getMainLooper())
    private var tickListenerId: Long = 0
    private val tick = object : Runnable {
        override fun run() {
            // 모든 suji_core_* 호출은 단일(UI) 스레드에서 — 코어가 single-threaded.
            SujiCore.nativeEmit("demo:tick", "{\"t\":${System.currentTimeMillis() / 1000}}")
            ui.postDelayed(this, 2000)
        }
    }

    companion object {
        /// SujiCore.onNativeEvent → emitToJs 위임 대상.
        var active: MainActivity? = null
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        active = this

        check(SujiCore.nativeInit() == 0) { "suji_core_init failed" }
        tickListenerId = SujiCore.nativeRegisterEvents("demo:tick")
        // 백엔드 없는 모바일에서 invoke 를 네이티브로 응답.
        SujiCore.nativeRegisterHandler("ping")
        SujiCore.nativeRegisterHandler("counter:inc")

        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.addJavascriptInterface(Bridge(), "SujiNative")
        setContentView(webView)
        webView.loadUrl("file:///android_asset/web/index.html")

        ui.postDelayed(tick, 2000)
    }

    override fun onDestroy() {
        ui.removeCallbacks(tick)
        if (tickListenerId != 0L) SujiCore.nativeOff(tickListenerId)
        SujiCore.nativeDestroy()
        if (active === this) active = null
        super.onDestroy()
    }

    private var counter = 0

    /// SujiCore.onInvoke 위임 대상 (UI 스레드). 백엔드 자리 네이티브 응답.
    fun handleInvoke(channel: String, json: String): String = when (channel) {
        "ping" -> "{\"pong\":true,\"from\":\"android-native\"}"
        "counter:inc" -> { counter++; "{\"n\":$counter}" }
        else -> "{}"
    }

    /// 네이티브 → JS. JSONObject.quote 로 안전한 JS 문자열 리터럴 생성.
    fun emitToJs(name: String, json: String) {
        val call = "window.__suji__.__emit__(${JSONObject.quote(name)}, ${JSONObject.quote(json)});"
        ui.post { webView.evaluateJavascript(call, null) }
    }

    private inner class Bridge {
        // JS → 네이티브. WebView JS 스레드에서 호출되므로 UI 스레드로 마샬링.
        @JavascriptInterface
        fun invoke(id: Int, channel: String, json: String) {
            ui.post {
                val resp = SujiCore.nativeInvoke(channel, json)
                val call = "window.__suji__.__resolve__($id, ${JSONObject.quote(resp)});"
                webView.evaluateJavascript(call, null)
            }
        }
    }
}
