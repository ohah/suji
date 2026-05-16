// JNI ↔ Suji 코어 C ABI 브리지.
// Kotlin SujiCore 의 external 함수 ↔ libsuji_core.a (정적 링크).

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "suji_core.h"

static JavaVM *g_vm = NULL;
// 트램폴린 hot path 비용 제거 — JNI_OnLoad 1회 캐싱 (FindClass/GetStaticMethodID
// 는 불변값이라 invoke/event 마다 재조회할 이유 없음).
static jclass g_suji_cls = NULL; // GlobalRef
static jmethodID g_event_mid = NULL;
static jmethodID g_invoke_mid = NULL;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_VERSION_1_6;
    jclass cls = (*env)->FindClass(env, "dev/suji/examples/android/SujiCore");
    if (cls != NULL) {
        g_suji_cls = (jclass)(*env)->NewGlobalRef(env, cls);
        g_event_mid = (*env)->GetStaticMethodID(
            env, cls, "onNativeEvent", "(Ljava/lang/String;Ljava/lang/String;)V");
        g_invoke_mid = (*env)->GetStaticMethodID(
            env, cls, "onInvoke",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
        (*env)->DeleteLocalRef(env, cls);
    }
    return JNI_VERSION_1_6;
}

JNIEXPORT jint JNICALL
Java_dev_suji_examples_android_SujiCore_nativeInit(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    return suji_core_init();
}

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeDestroy(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    suji_core_destroy();
}

JNIEXPORT jstring JNICALL
Java_dev_suji_examples_android_SujiCore_nativeInvoke(
    JNIEnv *env, jclass clazz, jstring channel, jstring json) {
    (void)clazz;
    const char *ch = (*env)->GetStringUTFChars(env, channel, NULL);
    const char *js = (*env)->GetStringUTFChars(env, json, NULL);

    const char *resp = suji_core_invoke(ch, js);
    jstring out = (*env)->NewStringUTF(env, resp ? resp : "");
    if (resp) suji_core_free(resp);

    (*env)->ReleaseStringUTFChars(env, channel, ch);
    (*env)->ReleaseStringUTFChars(env, json, js);
    return out;
}

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeEmit(
    JNIEnv *env, jclass clazz, jstring event, jstring json) {
    (void)clazz;
    const char *ev = (*env)->GetStringUTFChars(env, event, NULL);
    const char *js = (*env)->GetStringUTFChars(env, json, NULL);
    suji_core_emit(ev, js);
    (*env)->ReleaseStringUTFChars(env, event, ev);
    (*env)->ReleaseStringUTFChars(env, json, js);
}

// 네이티브 → JVM 이벤트 트램폴린. suji_core_on 콜백은 임의 스레드일 수 있어
// JavaVM 으로 현재 스레드를 attach 한 뒤 SujiCore.onNativeEvent(String,String)
// (@JvmStatic) 를 호출한다.
static void event_trampoline(const char *name, const char *data, void *arg) {
    (void)arg;
    if (g_vm == NULL || g_suji_cls == NULL || g_event_mid == NULL) return;

    JNIEnv *env = NULL;
    int attached = 0;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) return;
        attached = 1;
    }

    jstring jn = (*env)->NewStringUTF(env, name ? name : "");
    jstring jd = (*env)->NewStringUTF(env, data ? data : "");
    (*env)->CallStaticVoidMethod(env, g_suji_cls, g_event_mid, jn, jd);
    // 핸들러가 던진 예외가 남으면 이후 JNI 호출이 UB — 삼켜 격리.
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, jn);
    (*env)->DeleteLocalRef(env, jd);
    if (attached) (*g_vm)->DetachCurrentThread(g_vm);
}

JNIEXPORT jlong JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterEvents(
    JNIEnv *env, jclass clazz, jstring event) {
    (void)clazz;
    const char *ev = (*env)->GetStringUTFChars(env, event, NULL);
    uint64_t id = suji_core_on(ev, event_trampoline, NULL);
    (*env)->ReleaseStringUTFChars(env, event, ev);
    return (jlong)id;
}

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeOff(
    JNIEnv *env, jclass clazz, jlong id) {
    (void)env; (void)clazz;
    suji_core_off((uint64_t)id);
}

// 호스트 invoke 핸들러 트램폴린. suji_core_invoke 안에서 동기 호출됨
// (MainActivity 가 UI 스레드에서 호출 → 이미 Java 스레드). SujiCore.onInvoke
// (String,String):String 를 호출하고 결과를 strdup 으로 C 소유 복사.
static const char *host_invoke_trampoline(const char *channel, const char *json) {
    if (g_vm == NULL || g_suji_cls == NULL || g_invoke_mid == NULL) return NULL;
    JNIEnv *env = NULL;
    int attached = 0;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) return NULL;
        attached = 1;
    }

    char *result = NULL;
    jstring jc = (*env)->NewStringUTF(env, channel ? channel : "");
    jstring jj = (*env)->NewStringUTF(env, json ? json : "");
    jstring jr = (jstring)(*env)->CallStaticObjectMethod(env, g_suji_cls, g_invoke_mid, jc, jj);
    // 핸들러 예외 시 결과 무시 + 폴백(NULL) — 이후 JNI 호출 UB 방지.
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        jr = NULL;
    }
    if (jr != NULL) {
        const char *s = (*env)->GetStringUTFChars(env, jr, NULL);
        if (s != NULL) {
            result = strdup(s);
            (*env)->ReleaseStringUTFChars(env, jr, s);
        }
        (*env)->DeleteLocalRef(env, jr);
    }
    (*env)->DeleteLocalRef(env, jc);
    (*env)->DeleteLocalRef(env, jj);
    if (attached) (*g_vm)->DetachCurrentThread(g_vm);
    return result;
}

static void host_free_trampoline(const char *ptr) {
    free((void *)ptr);
}

JNIEXPORT jint JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterHandler(
    JNIEnv *env, jclass clazz, jstring channel) {
    (void)clazz;
    const char *ch = (*env)->GetStringUTFChars(env, channel, NULL);
    int rc = suji_core_register_handler(ch, host_invoke_trampoline, host_free_trampoline);
    (*env)->ReleaseStringUTFChars(env, channel, ch);
    return rc;
}
