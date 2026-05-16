// JNI ↔ Suji 코어 C ABI 브리지.
// Kotlin SujiCore 의 external 함수 ↔ libsuji_core.a (정적 링크).

#include <jni.h>
#include <string.h>
#include "suji_core.h"

static JavaVM *g_vm = NULL;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
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
    if (g_vm == NULL) return;

    JNIEnv *env = NULL;
    int attached = 0;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) return;
        attached = 1;
    }

    jclass cls = (*env)->FindClass(env, "dev/suji/examples/android/SujiCore");
    if (cls != NULL) {
        jmethodID mid = (*env)->GetStaticMethodID(
            env, cls, "onNativeEvent",
            "(Ljava/lang/String;Ljava/lang/String;)V");
        if (mid != NULL) {
            jstring jn = (*env)->NewStringUTF(env, name ? name : "");
            jstring jd = (*env)->NewStringUTF(env, data ? data : "");
            (*env)->CallStaticVoidMethod(env, cls, mid, jn, jd);
            (*env)->DeleteLocalRef(env, jn);
            (*env)->DeleteLocalRef(env, jd);
        }
        (*env)->DeleteLocalRef(env, cls);
    }
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
