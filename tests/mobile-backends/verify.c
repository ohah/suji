// 모바일 정적 백엔드 메커니즘 호스트 검증 하니스 (CEF/iOS 무관).
//
// iOS 호스트(Swift Backends.swift)가 하는 것과 동일한 경로를 네이티브에서
// 그대로 재현: 코어 + Rust(staticlib) + Go(c-archive)를 한 바이너리에 정적
// 링크하고, suji_core_register_handler 로 채널을 백엔드에 연결한 뒤
// suji_core_invoke 왕복을 검증한다.
//
// 링크 성공 자체가 "언어 고유 심볼(suji_core_/suji_rs_/suji_go_/suji_zig_)이
// 충돌 없이 공존" 한다는 실증. WKWebView/iOS 코드서명/JIT 만 실기기 몫.
//
// `zig:http` 는 모바일 백엔드의 std.http 경로(suji.http.fetch 동등)를 실증한다.
// 외부 네트워크/TLS 의존 0 — 인프로세스 localhost 평문 HTTP 미니서버로 왕복.
// ⚠️ 모바일 HTTPS/TLS(특히 iOS std CA 번들 공백)·실기기·실 네트워크는 미검증.
//
// 빌드·실행: tests/mobile-backends/run.sh

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include "suji_core.h"
#include "suji_mobile_bridge.h" // (channel,json)→{"cmd":...} 공용 (JNI와 공유)

// 정적 링크된 백엔드의 언어 고유 진입점.
extern char *suji_rs_backend_handle_ipc(const char *req);
extern void suji_rs_backend_free(char *p);
extern void suji_rs_backend_init(const void *core);
extern char *suji_go_backend_handle_ipc(const char *req);
extern void suji_go_backend_free(char *p);
extern void suji_go_backend_init(const void *core);
extern char *suji_zig_backend_handle_ipc(const char *req);
extern void suji_zig_backend_free(char *p);
extern void suji_zig_backend_init(const void *core);

static const char *rust_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_rs_backend_handle_ipc(q);
    free(q);
    return r;
}
static void rust_f(const char *p) { suji_rs_backend_free((char *)p); }

static const char *go_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_go_backend_handle_ipc(q);
    free(q);
    return r;
}
static void go_f(const char *p) { suji_go_backend_free((char *)p); }

static const char *zig_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_zig_backend_handle_ipc(q);
    free(q);
    return r;
}
static void zig_f(const char *p) { suji_zig_backend_free((char *)p); }

// 인프로세스 localhost 평문 HTTP 서버 (zig:http 실증용). GET→고정 본문,
// POST→요청 바디 echo. 외부 네트워크/TLS 없이 std.http 왕복만 검증.
static int http_port = 0;

static void *http_server(void *arg) {
    int ls = (int)(long)arg;
    for (;;) {
        int cs = accept(ls, NULL, NULL);
        if (cs < 0) continue;
        // 단일 recv 가정 — 하니스가 통제하는 sub-MTU loopback 요청이라
        // 한 세그먼트로 도착(범용 HTTP 서버 아님, 검증 fixture 한정).
        char req[8192];
        ssize_t n = recv(cs, req, sizeof(req) - 1, 0);
        if (n <= 0) { close(cs); continue; }
        req[n] = 0;
        const char *body = "SUJI_HTTP_OK";
        char echo[4096];
        if (strncmp(req, "POST", 4) == 0) {
            char *p = strstr(req, "\r\n\r\n");
            if (p) { snprintf(echo, sizeof(echo), "%s", p + 4); body = echo; }
        }
        char resp[8400];
        int rn = snprintf(resp, sizeof(resp),
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
            "Content-Length: %zu\r\nConnection: close\r\n\r\n%s",
            strlen(body), body);
        send(cs, resp, rn, 0);
        close(cs);
    }
    return NULL;
}

// 커널 할당 포트(127.0.0.1:0)로 충돌 회피. 실패 시 -1.
static int start_http_server(void) {
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) return -1;
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    socklen_t al = sizeof(a);
    if (bind(ls, (struct sockaddr *)&a, sizeof(a)) < 0) { close(ls); return -1; }
    if (getsockname(ls, (struct sockaddr *)&a, &al) < 0) { close(ls); return -1; }
    http_port = ntohs(a.sin_port);
    if (listen(ls, 16) < 0) { close(ls); return -1; }
    pthread_t t;
    if (pthread_create(&t, NULL, http_server, (void *)(long)ls) != 0) { close(ls); return -1; }
    pthread_detach(t);
    return 0;
}

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
    suji_zig_backend_init(NULL);

    if (suji_core_register_handler("greet", rust_h, rust_f) != 0 ||
        suji_core_register_handler("add", rust_h, rust_f) != 0 ||
        suji_core_register_handler("go:ping", go_h, go_f) != 0 ||
        suji_core_register_handler("go:upper", go_h, go_f) != 0 ||
        suji_core_register_handler("zig:ping", zig_h, zig_f) != 0 ||
        suji_core_register_handler("zig:rev", zig_h, zig_f) != 0 ||
        suji_core_register_handler("zig:http", zig_h, zig_f) != 0) {
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

    printf("== Zig 정적 백엔드 ==\n");
    roundtrip("zig:ping", "{}", "zig-native", "zig ping");
    roundtrip("zig:rev", "{\"s\":\"abc\"}", "\"rev\":\"cba\"", "zig rev");

    printf("== Zig http (std.http → localhost 평문) ==\n");
    if (start_http_server() != 0) {
        printf("  [FAIL] localhost http server 기동 실패\n");
        total++;
        fails++;
    } else {
        char get_url[96];
        snprintf(get_url, sizeof(get_url),
                 "{\"url\":\"http://127.0.0.1:%d/\"}", http_port);
        roundtrip("zig:http", get_url, "\"status\":200", "zig http GET status");
        roundtrip("zig:http", get_url, "SUJI_HTTP_OK", "zig http GET body");
        char post_url[160];
        snprintf(post_url, sizeof(post_url),
                 "{\"url\":\"http://127.0.0.1:%d/echo\",\"payload\":\"ZIGPOST42\"}",
                 http_port);
        roundtrip("zig:http", post_url, "ZIGPOST42", "zig http POST echo");
    }
    roundtrip("zig:http", "{}", "MissingUrl", "zig http missing url → error");

    printf("== 안정성 / free 계약 (200x 교차) ==\n");
    int loop_fails = 0;
    for (int i = 0; i < 200; i++) {
        const char *a = suji_core_invoke("add", "{\"a\":1,\"b\":2}");
        if (!a || !strstr(a, "\"result\":3")) loop_fails++;
        suji_core_free(a);
        const char *g = suji_core_invoke("go:ping", "{}");
        if (!g || !strstr(g, "pong")) loop_fails++;
        suji_core_free(g);
        const char *z = suji_core_invoke("zig:ping", "{}");
        if (!z || !strstr(z, "pong")) loop_fails++;
        suji_core_free(z);
    }
    total++;
    if (loop_fails) fails++;
    printf("  [%s] 200x rust+go+zig 교차 invoke (불일치 %d)\n",
           loop_fails ? "FAIL" : "PASS", loop_fails);

    suji_core_destroy();

    printf("\n%s  (%d/%d)\n", fails ? "FAILED" : "ALL PASS", total - fails, total);
    return fails ? 1 : 0;
}
