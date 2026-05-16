// 멀티 변형 — Rust(.a 정적) + Go(.so c-shared) 정적 백엔드 등록.
// 코어 JNI 는 ../../_shared/cpp/suji_jni_core.c. 여기선 백엔드 트램폴린 +
// nativeRegisterStaticBackends 만(변형별로 다른 부분).

#include <jni.h>
#include <stdlib.h>
#include "suji_core.h"
#include "suji_mobile_bridge.h" // (channel,json)→{"cmd":...} 공용

extern char *suji_rs_backend_handle_ipc(const char *req);
extern void suji_rs_backend_free(char *p);
extern void suji_rs_backend_init(const void *core);
extern char *suji_go_backend_handle_ipc(const char *req);
extern void suji_go_backend_free(char *p);
extern void suji_go_backend_init(const void *core);

static const char *rust_backend_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL; // OOM → 코어가 "{}" 폴백
    char *r = suji_rs_backend_handle_ipc(q);
    free(q);
    return r;
}
static void rust_backend_f(const char *p) { suji_rs_backend_free((char *)p); }

static const char *go_backend_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_go_backend_handle_ipc(q);
    free(q);
    return r;
}
static void go_backend_f(const char *p) { suji_go_backend_free((char *)p); }

// _shared/cpp/suji_jni_core.c 공용 (변형마다 재구현 방지).
extern void suji_reg_backend(const char *ch,
                             const char *(*h)(const char *, const char *),
                             void (*f)(const char *));

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterStaticBackends(
    JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    suji_rs_backend_init(NULL); // cross-call 미사용 → null core
    suji_go_backend_init(NULL);
    suji_reg_backend("greet", rust_backend_h, rust_backend_f);
    suji_reg_backend("add", rust_backend_h, rust_backend_f);
    suji_reg_backend("go:ping", go_backend_h, go_backend_f);
    suji_reg_backend("go:upper", go_backend_h, go_backend_f);
}
