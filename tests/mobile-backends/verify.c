// 모바일 정적 백엔드 메커니즘 호스트 검증 하니스 (CEF/iOS 무관).
//
// iOS 호스트(Swift Backends.swift)가 하는 것과 동일한 경로를 네이티브에서
// 그대로 재현: 코어 + Rust(staticlib) + Go(c-archive)를 한 바이너리에 정적
// 링크하고, suji_core_register_handler 로 채널을 백엔드에 연결한 뒤
// suji_core_invoke 왕복을 검증한다.
//
// 링크 성공 자체가 "언어 고유 심볼(suji_core_/suji_rs_/suji_go_)이 충돌
// 없이 공존" 한다는 실증. WKWebView/iOS 코드서명/JIT 만 실기기 몫.
//
// 빌드·실행: tests/mobile-backends/run.sh

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "suji_core.h"

// 정적 링크된 백엔드의 언어 고유 진입점.
extern char *suji_rs_backend_handle_ipc(const char *req);
extern void suji_rs_backend_free(char *p);
extern void suji_rs_backend_init(const void *core);
extern char *suji_go_backend_handle_ipc(const char *req);
extern void suji_go_backend_free(char *p);
extern void suji_go_backend_init(const void *core);

// (channel,json) → {"cmd":"<channel>", <json 본문>} 브리지.
// Backends.swift bridgeRequest 의 경량 문자열 조립 버전.
static char *bridge(const char *ch, const char *json) {
    // non-empty 분기는 json 이 well-formed 단일객체(`{...}`)라 가정 — json 자체의
    // 닫는 `}` 가 결과를 닫는다. 비-객체/공백시작은 empty 분기로 흘림.
    // +32: 포맷 고정부(`{"cmd":"",`+NUL) 여유 (실사용은 strlen(json)-1).
    int empty = json == NULL || strcmp(json, "{}") == 0 || json[0] != '{';
    size_t n = strlen(ch) + (json ? strlen(json) : 0) + 32;
    char *buf = malloc(n);
    if (!buf) {
        perror("malloc");
        abort();
    }
    if (empty)
        snprintf(buf, n, "{\"cmd\":\"%s\"}", ch);
    else
        snprintf(buf, n, "{\"cmd\":\"%s\",%s", ch, json + 1); // json+1: skip '{'
    return buf;
}

static const char *rust_h(const char *ch, const char *j) {
    char *q = bridge(ch, j);
    char *r = suji_rs_backend_handle_ipc(q);
    free(q);
    return r;
}
static void rust_f(const char *p) { suji_rs_backend_free((char *)p); }

static const char *go_h(const char *ch, const char *j) {
    char *q = bridge(ch, j);
    char *r = suji_go_backend_handle_ipc(q);
    free(q);
    return r;
}
static void go_f(const char *p) { suji_go_backend_free((char *)p); }

static int fails = 0;
static int total = 0;

static void expect(const char *label, const char *got, const char *needle) {
    total++;
    int ok = got && strstr(got, needle) != NULL;
    printf("  [%s] %-28s want~%-16s resp=%s\n",
           ok ? "PASS" : "FAIL", label, needle, got ? got : "(null)");
    if (!ok) fails++;
}

// invoke + assert + free 한 사이클.
static void roundtrip(const char *ch, const char *json, const char *needle, const char *label) {
    const char *r = suji_core_invoke(ch, json);
    expect(label, r, needle);
    suji_core_free(r);
}

int main(void) {
    if (suji_core_init() != 0) {
        printf("FAIL: suji_core_init\n");
        return 1;
    }
    // 미초기화 가드는 헤드리스 zig 테스트가 커버. 여기선 backend init(null core
    // — cross-call 미사용)만.
    suji_rs_backend_init(NULL);
    suji_go_backend_init(NULL);

    if (suji_core_register_handler("greet", rust_h, rust_f) != 0 ||
        suji_core_register_handler("add", rust_h, rust_f) != 0 ||
        suji_core_register_handler("go:ping", go_h, go_f) != 0 ||
        suji_core_register_handler("go:upper", go_h, go_f) != 0) {
        printf("FAIL: register_handler\n");
        suji_core_destroy(); // init 후 실패 — LSan 클린 유지
        return 1;
    }

    printf("== Rust 정적 백엔드 ==\n");
    roundtrip("greet", "{\"name\":\"Suji\"}", "Hello, Suji", "rust greet");
    // serde_json 은 비ASCII를 escape 안 함 — UTF-8 가 무손실로 왕복하는지 검증.
    roundtrip("greet", "{\"name\":\"한글\"}", "Hello, 한글", "rust greet utf8");
    roundtrip("add", "{\"a\":19,\"b\":23}", "\"result\":42", "rust add pos");
    roundtrip("add", "{\"a\":-5,\"b\":2}", "\"result\":-3", "rust add neg");
    roundtrip("add", "{}", "\"result\":0", "rust add missing args");
    roundtrip("unknownrs", "{}", "{}", "unregistered → core {}");

    printf("== Go 정적 백엔드 ==\n");
    roundtrip("go:ping", "{}", "go-native-ios", "go ping");
    roundtrip("go:upper", "{\"s\":\"hello ios\"}", "HELLO IOS", "go upper");
    roundtrip("go:upper", "{\"s\":\"\"}", "\"upper\":\"\"", "go upper empty");
    roundtrip("go:upper", "{\"s\":\"AB12\"}", "AB12", "go upper noop");

    printf("== 안정성 / free 계약 (200x 교차) ==\n");
    int loop_fails = 0;
    for (int i = 0; i < 200; i++) {
        const char *a = suji_core_invoke("add", "{\"a\":1,\"b\":2}");
        if (!a || !strstr(a, "\"result\":3")) loop_fails++;
        suji_core_free(a);
        const char *g = suji_core_invoke("go:ping", "{}");
        if (!g || !strstr(g, "pong")) loop_fails++;
        suji_core_free(g);
    }
    total++;
    if (loop_fails) fails++;
    printf("  [%s] 200x rust+go 교차 invoke (불일치 %d)\n",
           loop_fails ? "FAIL" : "PASS", loop_fails);

    suji_core_destroy();

    printf("\n%s  (%d/%d)\n", fails ? "FAILED" : "ALL PASS", total - fails, total);
    return fails ? 1 : 0;
}
