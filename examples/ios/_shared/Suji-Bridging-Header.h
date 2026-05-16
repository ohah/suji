// Swift ← Suji 코어 C ABI. HEADER_SEARCH_PATHS 가 레포 include/ 를 가리킨다.
#include "suji_core.h"

// 정적 링크된 백엔드의 고유 심볼 진입점 (Rust=suji_rs_*, Go=suji_go_*).
// build-lib.sh 가 libsuji_rs_backend.a / libsuji_go_backend.a 를 스테이징·링크.
extern void suji_rs_backend_init(const void *core);
extern char *suji_rs_backend_handle_ipc(const char *request);
extern void suji_rs_backend_free(char *ptr);
extern void suji_rs_backend_destroy(void);

extern void suji_go_backend_init(const void *core);
extern char *suji_go_backend_handle_ipc(const char *request);
extern void suji_go_backend_free(char *ptr);
extern void suji_go_backend_destroy(void);

extern void suji_zig_backend_init(const void *core);
extern char *suji_zig_backend_handle_ipc(const char *request);
extern void suji_zig_backend_free(char *ptr);
extern void suji_zig_backend_destroy(void);
