package dev.suji.examples.android

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
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
        // 데스크톱과 동일한 @suji/api(clipboard 등)용 __core__ 네이티브 디스패치.
        SujiCore.nativeRegisterHandler("__core__")
        // 정적 링크 Rust/Go 백엔드 (greet/add=Rust, go:ping/go:upper=Go)
        SujiCore.nativeRegisterStaticBackends()

        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.addJavascriptInterface(Bridge(), "SujiNative")
        setContentView(webView)
        // Gradle assets.srcDirs=["../web"] 가 web/ 내용을 assets 루트로 병합 →
        // 번들 경로는 assets/index.html (web/ 접두어 아님).
        webView.loadUrl("file:///android_asset/index.html")

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
        "__core__" -> coreDispatch(json)
        else -> "{}"
    }

    /// 데스크톱 __core__(src/main.zig cefHandleCore) 의 Android 대응 — 같은
    /// @suji/api(coreCall→__suji__.core) 가 동작하도록 cmd 를 Android 네이티브로
    /// 디스패치. 응답은 데스크톱과 키-동형(프론트 무수정). JSONObject 로
    /// 직렬화해 text 이스케이프 drift 방지. 미지원 cmd 는 coreError 동형.
    private fun coreDispatch(json: String): String {
        val obj = try { JSONObject(json) } catch (e: Exception) { JSONObject() }
        val cmd = obj.optString("cmd", "")
        val resp = JSONObject().put("from", "zig-core").put("cmd", cmd)
        val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        when (cmd) {
            "clipboard_read_text" ->
                resp.put("text",
                    cb.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString() ?: "")
            "clipboard_write_text" -> {
                cb.setPrimaryClip(ClipData.newPlainText("suji", obj.optString("text", "")))
                resp.put("success", true)
            }
            "clipboard_clear" -> {
                // clearPrimaryClip() 은 API 28+ — 빈 ClipData 덮어쓰기로 하위호환.
                cb.setPrimaryClip(ClipData.newPlainText("", ""))
                resp.put("success", true)
            }
            else -> resp.put("success", false).put("error", "unknown_cmd")
        }
        return resp.toString()
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
