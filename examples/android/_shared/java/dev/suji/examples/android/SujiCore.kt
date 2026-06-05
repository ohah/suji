package dev.suji.examples.android

/// libsujihost.so (정적 링크된 libsuji_core.a) 의 JNI 바인딩.
object SujiCore {
    init { System.loadLibrary("sujihost") }

    external fun nativeInit(): Int
    external fun nativeDestroy()
    external fun nativeInvoke(channel: String, json: String): String
    external fun nativeEmit(event: String, json: String)
    external fun nativeRegisterEvents(event: String): Long
    external fun nativeOff(id: Long)
    external fun nativeRegisterHandler(channel: String): Int

    /// 권한 게이트(Stage 2) — 코어 suji_core_set_permissions/permission_check.
    external fun nativeSetPermissions(json: String): Int
    external fun nativePermissionCheck(family: String, value: String, isBackend: Int): Int

    /// 정적 링크된 Rust(.a)/Go(.so) 백엔드를 채널에 등록 (iOS 와 동형).
    external fun nativeRegisterStaticBackends()

    /// embedded CPython 백엔드 등록 (python 변형만). filesDir 하위에 추출된
    /// stdlib(`<filesDir>/python`)+main.py 로 Py_Initialize 후 등록 핸들러를
    /// suji_core 에 배선. python 변형 backends.c 만 구현 — MainActivity 가 python
    /// 에셋이 있을 때만 호출하므로(JNI lazy bind) 다른 변형엔 영향 없음.
    external fun nativeRegisterPythonBackend(filesDir: String): Int

    /// 네이티브 이벤트 수신 지점 (suji_jni.c event_trampoline 가 호출).
    /// 활성 호스트로 위임 — UI 스레드 전환은 호스트가 책임.
    @JvmStatic
    fun onNativeEvent(name: String, data: String) {
        MainActivity.active?.emitToJs(name, data)
    }

    /// 호스트 invoke 핸들러 (suji_jni.c host_invoke_trampoline 가 동기 호출).
    /// suji_core_invoke 가 UI 스레드에서 호출되므로 여기도 UI 스레드.
    @JvmStatic
    fun onInvoke(channel: String, json: String): String =
        MainActivity.active?.handleInvoke(channel, json) ?: "{}"
}
