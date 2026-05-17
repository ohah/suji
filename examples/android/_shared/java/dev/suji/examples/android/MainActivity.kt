package dev.suji.examples.android

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
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
    private var notifSeq = 0
    private var notifChannelReady = false

    private fun notifManager() =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureNotifChannel() {
        if (notifChannelReady || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        notifManager().createNotificationChannel(
            NotificationChannel(NOTIF_CHANNEL, "Suji", NotificationManager.IMPORTANCE_DEFAULT)
        )
        notifChannelReady = true
    }

    private val NOTIF_CHANNEL = "suji"

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
            "shell_open_external" -> {
                val ok = try {
                    val i = Intent(Intent.ACTION_VIEW, Uri.parse(obj.optString("url", "")))
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(i)
                    true
                } catch (e: Exception) { false }
                resp.put("success", ok)
            }
            "notification_is_supported" -> resp.put("supported", true)
            "notification_request_permission" ->
                // areNotificationsEnabled() 는 동기 — 현재 상태값(정직). API33+
                // POST_NOTIFICATIONS 런타임 프롬프트는 비동기라 별도(데스크톱
                // 동기 계약 유지 위해 현재값 반환).
                resp.put("granted", notifManager().areNotificationsEnabled())
            "notification_show" -> {
                val n = notifSeq++
                val nid = "suji-notif-$n"
                ensureNotifChannel()
                // Notification.Builder(Context,String) 은 API 26+ (예제 minSdk 전제).
                val builder = Notification.Builder(this, NOTIF_CHANNEL)
                    .setContentTitle(obj.optString("title", ""))
                    .setContentText(obj.optString("body", ""))
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                if (obj.optBoolean("silent", false)) builder.setSound(null)
                notifManager().notify(n, builder.build())
                resp.put("notificationId", nid).put("success", true)
            }
            "notification_close" -> {
                val nid = obj.optString("notificationId", "")
                nid.removePrefix("suji-notif-").toIntOrNull()?.let { notifManager().cancel(it) }
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

    /// 데스크톱 dialog_show_message_box 와 키-동형 응답. setItems 로 버튼
    /// 임의 개수(Electron buttons[]) → response=index. AlertDialog 는 네이티브
    /// 체크박스가 없어 checkboxChecked 는 항상 false(정직한 플랫폼 한계).
    /// 취소 시 response=0(프론트 graceful).
    private fun presentMessageBox(id: Int, opts: JSONObject) {
        val arr = opts.optJSONArray("buttons")
        val labels = if (arr != null && arr.length() > 0)
            Array(arr.length()) { arr.optString(it) } else arrayOf("OK")
        fun resolve(which: Int) {
            val r = JSONObject().put("from", "zig-core")
                .put("cmd", "dialog_show_message_box")
                .put("response", which).put("checkboxChecked", false)
            webView.evaluateJavascript(
                "window.__suji__.__resolve__($id, ${JSONObject.quote(r.toString())});", null)
        }
        AlertDialog.Builder(this)
            .setTitle(opts.optString("title").ifEmpty { null })
            .setMessage(opts.optString("message"))
            .setItems(labels) { _, which -> resolve(which) }
            .setOnCancelListener { resolve(0) }
            .show()
    }

    private inner class Bridge {
        // JS → 네이티브. WebView JS 스레드에서 호출되므로 UI 스레드로 마샬링.
        @JavascriptInterface
        fun invoke(id: Int, channel: String, json: String) {
            ui.post {
                // dialog 는 사용자 응답 비동기 — 동기 nativeInvoke 로는 불가.
                // 호스트에서 가로채 AlertDialog 표시 후 같은 id 로 resolve
                // (코어 무변경). 비-dialog 는 기존 동기 경로.
                if (channel == "__core__") {
                    val o = try { JSONObject(json) } catch (e: Exception) { JSONObject() }
                    if (o.optString("cmd") == "dialog_show_message_box") {
                        presentMessageBox(id, o)
                        return@post
                    }
                }
                val resp = SujiCore.nativeInvoke(channel, json)
                val call = "window.__suji__.__resolve__($id, ${JSONObject.quote(resp)});"
                webView.evaluateJavascript(call, null)
            }
        }
    }
}
