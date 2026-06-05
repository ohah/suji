// python 변형 — embedded CPython 백엔드(suji_python_backend_*) 등록.
// 코어 JNI 는 ../../_shared/cpp/suji_jni_core.c. iOS 와 달리 핸들러가 동적이고
// PYTHONHOME 이 실 FS 경로라, MainActivity 가 filesDir(추출된 stdlib/main.py)를
// 넘겨 nativeRegisterPythonBackend 를 호출 → start + channels(JSON) 파싱 →
// 각 채널을 suji_reg_backend 로 등록(데스크탑/iOS 채널=핸들러 의미 보존).

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "suji_core.h"
#include "suji_mobile_bridge.h"

extern void suji_python_backend_init(const void *core);
extern int suji_python_backend_start(const char *home, const char *entry);
extern char *suji_python_backend_channels(void);
extern char *suji_python_backend_handle_ipc(const char *req);
extern void suji_python_backend_free(char *p);

// _shared/cpp/suji_jni_core.c 공용 (suji_core_register_handler 래퍼).
extern void suji_reg_backend(const char *ch,
                             const char *(*h)(const char *, const char *),
                             void (*f)(const char *));

static const char *python_backend_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_python_backend_handle_ipc(q);
    free(q);
    return r;
}
static void python_backend_f(const char *p) { suji_python_backend_free((char *)p); }

// channels JSON 배열(["ping","echo"])에서 따옴표 문자열을 순회하며 각 채널 등록.
// 핸들러 이름은 식별자라 escape 없음(suji_python_backend_channels 와 동일 가정).
// 코어가 channel 을 dupe(registerEmbedRuntime)하므로 name 은 등록 후 free.
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
        suji_reg_backend(name, python_backend_h, python_backend_f);
        free(name);
        p = end + 1;
    }
}

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterStaticBackends(
    JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    // python 등록은 경로가 필요해 nativeRegisterPythonBackend 에서. 여기선 no-op.
}

JNIEXPORT jint JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterPythonBackend(
    JNIEnv *env, jclass clazz, jstring jFilesDir) {
    (void)clazz;
    const char *files_dir = (*env)->GetStringUTFChars(env, jFilesDir, NULL);
    if (!files_dir) return -1;

    char home[1024], entry[1024];
    snprintf(home, sizeof home, "%s/python", files_dir);   // PYTHONHOME (stdlib 상위)
    snprintf(entry, sizeof entry, "%s/main.py", files_dir); // 엔트리
    (*env)->ReleaseStringUTFChars(env, jFilesDir, files_dir);

    suji_python_backend_init(NULL);
    if (suji_python_backend_start(home, entry) != 0) return -2;

    char *chans = suji_python_backend_channels();
    if (chans) {
        register_channels(chans);
        suji_python_backend_free(chans);
    }
    return 0;
}
