// rust 단독 변형 — Rust(.a 정적) 백엔드만 등록.
// 코어 JNI 는 ../../_shared/cpp/suji_jni_core.c.

#include <jni.h>
#include <stdlib.h>
#include "suji_core.h"
#include "suji_mobile_bridge.h"

extern char *suji_rs_backend_handle_ipc(const char *req);
extern void suji_rs_backend_free(char *p);
extern void suji_rs_backend_init(const void *core);

// _shared/cpp/suji_jni_core.c 공용.
extern void suji_reg_backend(const char *ch,
                             const char *(*h)(const char *, const char *),
                             void (*f)(const char *));

static const char *rust_backend_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_rs_backend_handle_ipc(q);
    free(q);
    return r;
}
static void rust_backend_f(const char *p) { suji_rs_backend_free((char *)p); }

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterStaticBackends(
    JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    suji_rs_backend_init(NULL);
    suji_reg_backend("greet", rust_backend_h, rust_backend_f);
    suji_reg_backend("add", rust_backend_h, rust_backend_f);
}
