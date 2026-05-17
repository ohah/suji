package dev.suji.examples.android

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
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
        // e2e.html verdict 보고 채널 (android-e2e.sh 가 logcat 으로 회수).
        SujiCore.nativeRegisterHandler("e2e:report")
        // 정적 링크 Rust/Go 백엔드 (greet/add=Rust, go:ping/go:upper=Go)
        SujiCore.nativeRegisterStaticBackends()

        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.addJavascriptInterface(Bridge(), "SujiNative")
        setContentView(webView)
        // Gradle assets.srcDirs=["../web"] 가 web/ 내용을 assets 루트로 병합 →
        // 번들 경로는 assets/index.html (web/ 접두어 아님). e2e 모드
        // (android-e2e.sh 가 --es suji_e2e 1)면 e2e.html — 데모 무회귀.
        val page = if (intent?.getStringExtra("suji_e2e") == "1") "e2e" else "index"
        webView.loadUrl("file:///android_asset/$page.html")

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
        "e2e:report" -> {
            // android-e2e.sh 가 logcat 태그 grep 으로 회수(+filesDir 파일 폴백).
            Log.i("SujiE2E", "SUJI_E2E_RESULT $json")
            runCatching { openFileOutput("suji-e2e-report.json", MODE_PRIVATE)
                .use { it.write(json.toByteArray()) } }
            "{\"ok\":true}"
        }
        // __core__ 등록 핸들러는 coreInvoke 가 *추출된 cmd* 를 channel 인자로
        // 넘긴다(embed_runtimes 폴백, extractCmdField) — 즉 여기 channel 은
        // "__core__" 가 아니라 "clipboard_write_text" 등. coreDispatch 가 json
        // 의 cmd 로 재분기(iOS sujiCoreDispatch 와 동형). 미지원은 coreError.
        else -> coreDispatch(json)
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
            "clipboard_write_html" -> {
                val h = obj.optString("html")
                cb.setPrimaryClip(ClipData.newHtmlText("suji", h, h))
                resp.put("success", true)
            }
            "clipboard_read_html" ->
                resp.put("html", cb.primaryClip?.getItemAt(0)?.htmlText ?: "")
            "clipboard_write_rtf" -> {
                clipCustomWrite("text/rtf", obj.optString("rtf")); resp.put("success", true)
            }
            "clipboard_read_rtf" -> resp.put("rtf", clipCustomRead("text/rtf"))
            "clipboard_write_image" -> {
                // ⚠️ Android 시스템 클립보드는 in-band image 네이티브 타입이
                // 없음(content:// URI+FileProvider 필요). 데스크톱 raw PNG
                // base64 패리티를 위해 custom MIME 으로 왕복 — 앱 내 동작하나
                // 타 앱 이미지 클립과 상호운용 아님(플랫폼 한계, 정직).
                clipCustomWrite("application/x-suji-png-b64", obj.optString("data"))
                resp.put("success", true)
            }
            "clipboard_read_image" ->
                resp.put("data", clipCustomRead("application/x-suji-png-b64"))
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
            "safe_storage_set", "safe_storage_get", "safe_storage_delete" ->
                safeStorage(cmd, obj, resp)
            "app_get_locale" ->
                resp.put("locale", java.util.Locale.getDefault().toLanguageTag())
            "app_get_name" -> resp.put("name",
                runCatching { packageManager.getApplicationLabel(applicationInfo).toString() }
                    .getOrDefault(packageName))
            "app_get_version" -> resp.put("version",
                runCatching {
                    packageManager.getPackageInfo(packageName, 0).versionName ?: ""
                }.getOrDefault(""))
            "app_get_path" -> {
                // Android 매핑. ⚠️ desktop 은 데스크톱에선 ~/Desktop(non-empty)
                // 지원 키지만 Android 플랫폼 부재로 graceful 빈 문자열 격하
                // (데스크톱 진짜 unknown 키와 동일 *형태*일 뿐 의미 동형 아님).
                val p = when (obj.optString("name")) {
                    "home" -> filesDir.parent ?: filesDir.path
                    "temp" -> cacheDir.path
                    "appData", "userData" -> filesDir.path
                    "documents" ->
                        (getExternalFilesDir("Documents")?.path ?: filesDir.path)
                    "downloads" ->
                        (getExternalFilesDir("Download")?.path ?: "")
                    else -> "" // desktop(데스크톱 지원)/진짜 unknown → 빈값 격하
                }
                resp.put("path", p)
            }
            else -> resp.put("success", false).put("error", "unknown_cmd")
        }
        return resp.toString()
    }

    /// 데스크톱 Keychain(safe_storage)의 Android 대응 — Android Keystore 의
    /// 하드웨어-백 AES-GCM 키로 value 를 암호화해 SharedPreferences 에 저장
    /// (androidx.security 의존 없이 stdlib 만). 응답 데스크톱 키-동형
    /// (set/delete=success, get=value, idempotent).
    private fun ssKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry("suji_ss", null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        kg.init(
            KeyGenParameterSpec.Builder(
                "suji_ss",
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return kg.generateKey()
    }

    // Android 시스템 클립보드는 RTF/in-band image 네이티브 타입이 없어
    // custom MIME ClipData 로 왕복(앱 내 동작, 타 앱 RTF/이미지 상호운용
    // 아님 — 플랫폼 한계). HTML 은 ClipData.newHtmlText 네이티브 사용.
    private fun clipCustomWrite(mime: String, payload: String) {
        val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cb.setPrimaryClip(ClipData(ClipDescription("suji", arrayOf(mime)),
                                   ClipData.Item(payload)))
    }

    private fun clipCustomRead(mime: String): String {
        val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = cb.primaryClip ?: return ""
        return if (clip.description.hasMimeType(mime))
            clip.getItemAt(0).text?.toString() ?: "" else ""
    }

    private fun safeStorage(cmd: String, obj: JSONObject, resp: JSONObject) {
        val prefs = getSharedPreferences("suji_safe_storage", MODE_PRIVATE)
        val k = obj.optString("service") + " " + obj.optString("account")
        when (cmd) {
            "safe_storage_set" -> {
                val ok = runCatching {
                    val c = Cipher.getInstance("AES/GCM/NoPadding")
                    c.init(Cipher.ENCRYPT_MODE, ssKey())
                    val ct = c.doFinal(obj.optString("value").toByteArray())
                    val blob = c.iv + ct // GCM 표준 12B nonce(c.iv) prepend → get 에서 분리
                    prefs.edit().putString(k, Base64.encodeToString(blob, Base64.NO_WRAP)).commit()
                }.isSuccess
                resp.put("success", ok)
            }
            "safe_storage_get" -> {
                val v = runCatching {
                    val blob = Base64.decode(
                        prefs.getString(k, null) ?: return@runCatching "", Base64.NO_WRAP)
                    val c = Cipher.getInstance("AES/GCM/NoPadding")
                    c.init(Cipher.DECRYPT_MODE, ssKey(), GCMParameterSpec(128, blob, 0, 12))
                    String(c.doFinal(blob, 12, blob.size - 12))
                }.getOrDefault("")
                resp.put("value", v)
            }
            else -> { // safe_storage_delete — 미존재도 true(idempotent)
                prefs.edit().remove(k).commit()
                resp.put("success", true)
            }
        }
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
