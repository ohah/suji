// node 변형 — embedded Node.js 백엔드(libnode + 데스크톱 bridge.cc) 등록.
// 코어 JNI 는 ../../_shared/cpp/suji_jni_core.c. python 변형과 동형이나 핸들러
// 디스패치는 suji_node_invoke(channel, data) 로 channel 을 별도 인자로 받는다
// (python handle_ipc 단일 req 와 차이 — node bridge 가 g_handlers[channel] 매칭).
// MainActivity 가 filesDir(복사된 main.js/main.ts)를 넘겨 nativeRegisterNodeBackend
// → init + run_async + wait_ready + channels → 각 채널을 suji_reg_backend 로 등록.

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "suji_core.h"
#include "suji_mobile_bridge.h"

extern int suji_node_init(int argc, char **argv);
extern int suji_node_run_async(const char *entry_path);
extern int suji_node_wait_ready(int timeout_ms);
extern const char *suji_node_invoke(const char *channel, const char *data);
extern void suji_node_free(const char *ptr);
extern char *suji_node_channels(void);

// _shared/cpp/suji_jni_core.c 공용 (suji_core_register_handler 래퍼).
extern void suji_reg_backend(const char *ch,
                             const char *(*h)(const char *, const char *),
                             void (*f)(const char *));

// 핸들러: (channel,json) → {"cmd":channel,...json}(데스크톱 request 형식) →
// suji_node_invoke(channel, request). 데스크톱 coreInvoke 가 node 핸들러에 넘기는
// request 와 키-동형(main.js 의 JSON.parse(data).cmd 보존).
static const char *node_backend_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    const char *r = suji_node_invoke(ch, q);
    free(q);
    return r;
}
static void node_backend_f(const char *p) { suji_node_free(p); }

// channels JSON 배열(["ping","echo"])에서 채널명을 순회하며 각각 등록
// (python register_channels 동형 — 채널명은 식별자 가정, escape 없음).
static void register_channels(const char *json) {
    const char *p = json;
    while ((p = strchr(p, '"')) != NULL) {
        const char *end = strchr(p + 1, '"');
        if (!end) break;
        size_t n = (size_t)(end - (p + 1));
        char *name = (char *)malloc(n + 1);
        if (!name) break;
        memcpy(name, p + 1, n);
        name[n] = '\0';
        suji_reg_backend(name, node_backend_h, node_backend_f);
        free(name);
        p = end + 1;
    }
}

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterStaticBackends(
    JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    // node 등록은 entry 경로가 필요해 nativeRegisterNodeBackend 에서. 여기선 no-op.
}

JNIEXPORT jint JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterNodeBackend(
    JNIEnv *env, jclass clazz, jstring jFilesDir, jstring jEntry) {
    (void)clazz;
    const char *files_dir = (*env)->GetStringUTFChars(env, jFilesDir, NULL);
    if (!files_dir) return -1;
    const char *entry_name = (*env)->GetStringUTFChars(env, jEntry, NULL);
    if (!entry_name) {
        (*env)->ReleaseStringUTFChars(env, jFilesDir, files_dir);
        return -1;
    }

    // MainActivity 가 결정·복사한 엔트리(main.js 우선, 없으면 main.ts)를 그대로
    // 사용 — Kotlin 이 이미 어느 파일인지 알므로 네이티브에서 재탐색하지 않는다.
    char entry[1024];
    snprintf(entry, sizeof entry, "%s/%s", files_dir, entry_name);
    (*env)->ReleaseStringUTFChars(env, jEntry, entry_name);
    (*env)->ReleaseStringUTFChars(env, jFilesDir, files_dir);

    char arg0[] = "suji-node";
    char *argv[] = {arg0};
    if (suji_node_init(1, argv) != 0) return -2;
    if (suji_node_run_async(entry) != 0) return -3;
    suji_node_wait_ready(10000); // best-effort — main.js 핸들러 등록 대기

    char *chans = suji_node_channels();
    if (chans) {
        register_channels(chans);
        suji_node_free(chans);
    }
    return 0;
}
