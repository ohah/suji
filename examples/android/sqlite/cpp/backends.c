// sqlite 변형 — SQLite(.a 정적, 벤더 sqlite3.c) 백엔드만 등록
// (suji_sqlite_backend_*). 데스크탑 plugins/sqlite 모바일 대응.
// 코어 JNI 는 ../../_shared/cpp/suji_jni_core.c.

#include <jni.h>
#include <stdlib.h>
#include "suji_core.h"
#include "suji_mobile_bridge.h"

extern char *suji_sqlite_backend_handle_ipc(const char *req);
extern void suji_sqlite_backend_free(char *p);
extern void suji_sqlite_backend_init(const void *core);

// _shared/cpp/suji_jni_core.c 공용.
extern void suji_reg_backend(const char *ch,
                             const char *(*h)(const char *, const char *),
                             void (*f)(const char *));

static const char *sqlite_backend_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_sqlite_backend_handle_ipc(q);
    free(q);
    return r;
}
static void sqlite_backend_f(const char *p) { suji_sqlite_backend_free((char *)p); }

JNIEXPORT void JNICALL
Java_dev_suji_examples_android_SujiCore_nativeRegisterStaticBackends(
    JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    suji_sqlite_backend_init(NULL);
    suji_reg_backend("sql:open", sqlite_backend_h, sqlite_backend_f);
    suji_reg_backend("sql:execute", sqlite_backend_h, sqlite_backend_f);
    suji_reg_backend("sql:query", sqlite_backend_h, sqlite_backend_f);
    suji_reg_backend("sql:close", sqlite_backend_h, sqlite_backend_f);
}
