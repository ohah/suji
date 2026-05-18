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
extern char *suji_sqlite_backend_handle_ipc(const char *req);
extern void suji_sqlite_backend_free(char *p);
extern void suji_sqlite_backend_init(const void *core);

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

static const char *sqlite_h(const char *ch, const char *j) {
    char *q = suji_mobile_bridge(ch, j);
    if (!q) return NULL;
    char *r = suji_sqlite_backend_handle_ipc(q);
    free(q);
    return r;
}
static void sqlite_f(const char *p) { suji_sqlite_backend_free((char *)p); }

// __core__ 모바일 디스패처 mock. iOS sujiCoreDispatch / Android coreDispatch 와
// 동일 계약을 C 로 흉내 — register_handler("__core__") 라우팅과 데스크톱
// cefHandleCore 와 키-동형 응답 포맷을 자동 실증한다. ⚠️ C 하니스라 실
// UIPasteboard/ClipboardManager 는 못 탐 — 라우팅+응답포맷만 검증(실 네이티브
// 동작은 시뮬레이터/실기기 몫, 정직). coreInvoke 가 cmd 를 추출해 channel 인자로
// 넘기므로(loader.zig embed_runtimes 폴백) ch == cmd.
static char mock_clip[256];
static char mock_ss[256];
static char mock_html[512];
static char mock_rtf[512];
static char mock_img[1024];
static char mock_fs[1024];
static char mock_buf[1024];

// "key":"..." 값을 dst 로 추출(escape 미지원 단순 스캐너 — 테스트 입력 통제).
static void mock_extract(const char *j, const char *quoted_key, char *dst, size_t cap) {
    dst[0] = 0;
    const char *p = j ? strstr(j, quoted_key) : NULL;
    if (!p) return;
    p += strlen(quoted_key);
    const char *e = strchr(p, '"');
    size_t n = e ? (size_t)(e - p) : 0;
    if (n >= cap) n = cap - 1;
    memcpy(dst, p, n);
    dst[n] = 0;
}

static const char *core_h(const char *ch, const char *j) {
    char buf[512];
    if (strcmp(ch, "clipboard_read_text") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_text\",\"text\":\"%s\"}",
            mock_clip);
    } else if (strcmp(ch, "clipboard_write_text") == 0) {
        // escape 미지원 단순 스캐너 — 테스트 입력(ASCII, escape 없음) 통제 전제.
        const char *p = j ? strstr(j, "\"text\":\"") : NULL;
        mock_clip[0] = 0;
        if (p) {
            p += 8;
            const char *e = strchr(p, '"');
            size_t n = e ? (size_t)(e - p) : 0;
            if (n >= sizeof(mock_clip)) n = sizeof(mock_clip) - 1;
            memcpy(mock_clip, p, n);
            mock_clip[n] = 0;
        }
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_text\",\"success\":true}");
    } else if (strcmp(ch, "clipboard_clear") == 0) {
        mock_clip[0] = 0;
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_clear\",\"success\":true}");
    } else if (strcmp(ch, "shell_open_external") == 0) {
        // mock — 실 open 은 iOS UIApplication / Android Intent 몫. 라우팅+포맷만.
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"shell_open_external\",\"success\":true}");
    } else if (strcmp(ch, "notification_is_supported") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"notification_is_supported\",\"supported\":true}");
    } else if (strcmp(ch, "notification_request_permission") == 0) {
        // mock — iOS 는 비동기라 실제론 false+이벤트, Android 는 동기. 포맷만.
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"notification_request_permission\",\"granted\":true}");
    } else if (strcmp(ch, "notification_show") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"notification_show\",\"notificationId\":\"suji-notif-0\",\"success\":true}");
    } else if (strcmp(ch, "notification_close") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"notification_close\",\"success\":true}");
    } else if (strcmp(ch, "safe_storage_set") == 0) {
        const char *p = j ? strstr(j, "\"value\":\"") : NULL;
        mock_ss[0] = 0;
        if (p) {
            p += 9;
            const char *e = strchr(p, '"');
            size_t n = e ? (size_t)(e - p) : 0;
            if (n >= sizeof(mock_ss)) n = sizeof(mock_ss) - 1;
            memcpy(mock_ss, p, n);
            mock_ss[n] = 0;
        }
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"safe_storage_set\",\"success\":true}");
    } else if (strcmp(ch, "safe_storage_get") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"safe_storage_get\",\"value\":\"%s\"}",
            mock_ss);
    } else if (strcmp(ch, "safe_storage_delete") == 0) {
        mock_ss[0] = 0;
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"safe_storage_delete\",\"success\":true}");
    } else if (strcmp(ch, "app_get_locale") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"app_get_locale\",\"locale\":\"en-US\"}");
    } else if (strcmp(ch, "app_get_name") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"app_get_name\",\"name\":\"SujiMock\"}");
    } else if (strcmp(ch, "app_get_version") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"app_get_version\",\"version\":\"1.0.0\"}");
    } else if (strcmp(ch, "clipboard_write_html") == 0) {
        mock_extract(j, "\"html\":\"", mock_html, sizeof(mock_html));
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_html\",\"success\":true}");
    } else if (strcmp(ch, "clipboard_read_html") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_html\",\"html\":\"%s\"}",
            mock_html);
    } else if (strcmp(ch, "clipboard_write_rtf") == 0) {
        mock_extract(j, "\"rtf\":\"", mock_rtf, sizeof(mock_rtf));
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_rtf\",\"success\":true}");
    } else if (strcmp(ch, "clipboard_read_rtf") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_rtf\",\"rtf\":\"%s\"}",
            mock_rtf);
    } else if (strcmp(ch, "clipboard_write_image") == 0) {
        mock_extract(j, "\"data\":\"", mock_img, sizeof(mock_img));
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_image\",\"success\":true}");
    } else if (strcmp(ch, "clipboard_read_image") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_image\",\"data\":\"%s\"}",
            mock_img);
    } else if (strcmp(ch, "shell_beep") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"shell_beep\",\"success\":true}");
    } else if (strcmp(ch, "shell_open_path") == 0 ||
               strcmp(ch, "shell_show_item_in_folder") == 0 ||
               strcmp(ch, "shell_trash_item") == 0) {
        // mock — 모바일 한계로 graceful false(데스크톱 키-동형). 라우팅+포맷만.
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"%s\",\"success\":false}", ch);
    } else if (strcmp(ch, "clipboard_write_buffer") == 0) {
        mock_extract(j, "\"data\":\"", mock_buf, sizeof(mock_buf));
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_write_buffer\",\"success\":true}");
    } else if (strcmp(ch, "clipboard_read_buffer") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_read_buffer\",\"data\":\"%s\"}",
            mock_buf);
    } else if (strcmp(ch, "clipboard_has") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_has\",\"present\":true}");
    } else if (strcmp(ch, "clipboard_available_formats") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"clipboard_available_formats\","
            "\"formats\":[\"application/x-suji-buf\"]}");
    } else if (strcmp(ch, "fs_stat") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"fs_stat\",\"success\":true,"
            "\"type\":\"file\",\"size\":6,\"mtime\":1700000000000}");
    } else if (strcmp(ch, "fs_mkdir") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"fs_mkdir\",\"success\":true}");
    } else if (strcmp(ch, "fs_rm") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"fs_rm\",\"success\":true}");
    } else if (strcmp(ch, "fs_write_file") == 0) {
        mock_extract(j, "\"text\":\"", mock_fs, sizeof(mock_fs));
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"fs_write_file\",\"success\":true}");
    } else if (strcmp(ch, "fs_read_file") == 0) {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"fs_read_file\",\"success\":true,\"text\":\"%s\"}",
            mock_fs);
    } else if (strcmp(ch, "fs_readdir") == 0) {
        // mock — 실 FS 는 iOS FileManager / Android File 몫. 라우팅+키-동형만.
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"fs_readdir\",\"success\":true,"
            "\"entries\":[{\"name\":\"suji-e2e-fs.txt\",\"type\":\"file\"}]}");
    } else if (strcmp(ch, "app_get_path") == 0) {
        // mock — 실 경로는 iOS FileManager / Android filesDir 몫. 라우팅+포맷만.
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"app_get_path\",\"path\":\"/mock/docs\"}");
    } else {
        snprintf(buf, sizeof(buf),
            "{\"from\":\"zig-core\",\"cmd\":\"%s\",\"success\":false,\"error\":\"unknown_cmd\"}",
            ch);
    }
    return strdup(buf);
}
static void core_f(const char *p) { free((char *)p); }

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
    suji_sqlite_backend_init(NULL);

    if (suji_core_register_handler("greet", rust_h, rust_f) != 0 ||
        suji_core_register_handler("add", rust_h, rust_f) != 0 ||
        suji_core_register_handler("go:ping", go_h, go_f) != 0 ||
        suji_core_register_handler("go:upper", go_h, go_f) != 0 ||
        suji_core_register_handler("zig:ping", zig_h, zig_f) != 0 ||
        suji_core_register_handler("zig:rev", zig_h, zig_f) != 0 ||
        suji_core_register_handler("zig:http", zig_h, zig_f) != 0 ||
        suji_core_register_handler("sql:open", sqlite_h, sqlite_f) != 0 ||
        suji_core_register_handler("sql:execute", sqlite_h, sqlite_f) != 0 ||
        suji_core_register_handler("sql:query", sqlite_h, sqlite_f) != 0 ||
        suji_core_register_handler("sql:close", sqlite_h, sqlite_f) != 0 ||
        suji_core_register_handler("__core__", core_h, core_f) != 0) {
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

    // SQLite 정적 백엔드 — 데스크탑 plugins/sqlite 모바일 대응(suji_sqlite_*).
    // 실 SQLite CRUD 를 모바일 경로(register_handler→bridge→handle_ipc)로 왕복.
    printf("== SQLite 정적 백엔드 (실 sqlite3, 모바일 경로) ==\n");
    {
        const char *o = suji_core_invoke("sql:open", "{\"path\":\":memory:\"}");
        int db = -1;
        const char *idp = o ? strstr(o, "\"dbId\":") : NULL;
        if (idp) db = atoi(idp + 7);
        expect("sqlite open :memory:", o, "\"dbId\":");
        suji_core_free(o);

        char req[256];
        snprintf(req, sizeof(req),
            "{\"dbId\":%d,\"sql\":\"CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)\"}", db);
        roundtrip("sql:execute", req, "\"changes\":0", "sqlite create table");

        snprintf(req, sizeof(req),
            "{\"dbId\":%d,\"sql\":\"INSERT INTO t(name) VALUES (?)\",\"params\":[\"한글yoon\"]}", db);
        roundtrip("sql:execute", req, "\"lastInsertRowid\":1", "sqlite insert(params)");

        snprintf(req, sizeof(req),
            "{\"dbId\":%d,\"sql\":\"SELECT id, name FROM t WHERE name = ?\",\"params\":[\"한글yoon\"]}", db);
        roundtrip("sql:query", req, "\"name\":\"한글yoon\"", "sqlite query(params, utf8)");
        snprintf(req, sizeof(req),
            "{\"dbId\":%d,\"sql\":\"SELECT id, name FROM t WHERE name = ?\",\"params\":[\"한글yoon\"]}", db);
        roundtrip("sql:query", req, "\"id\":1", "sqlite query rowid");

        // injection-safe: 악성 입력은 리터럴 저장(테이블 안 드랍).
        snprintf(req, sizeof(req),
            "{\"dbId\":%d,\"sql\":\"INSERT INTO t(name) VALUES (?)\",\"params\":[\"x'); DROP TABLE t;--\"]}", db);
        roundtrip("sql:execute", req, "\"changes\":1", "sqlite injection-safe insert");
        snprintf(req, sizeof(req), "{\"dbId\":%d,\"sql\":\"SELECT COUNT(*) c FROM t\"}", db);
        roundtrip("sql:query", req, "\"c\":2", "sqlite table survived injection");

        snprintf(req, sizeof(req), "{\"dbId\":%d}", db);
        roundtrip("sql:close", req, "\"ok\":true", "sqlite close");
        snprintf(req, sizeof(req), "{\"dbId\":%d,\"sql\":\"SELECT 1\"}", db);
        roundtrip("sql:query", req, "invalid dbId", "sqlite use-after-close → error");
        roundtrip("sql:open", "{\"path\":\"rel/path.db\"}", "invalid path",
                  "sqlite relative path rejected (mobile boundary)");
    }

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

    printf("== __core__ 네이티브 디스패치 (clipboard, 모바일=iOS/Android 동형) ==\n");
    roundtrip("__core__", "{\"cmd\":\"clipboard_write_text\",\"text\":\"SujiClip\"}",
              "\"cmd\":\"clipboard_write_text\",\"success\":true", "core clipboard write");
    roundtrip("__core__", "{\"cmd\":\"clipboard_read_text\"}",
              "\"text\":\"SujiClip\"", "core clipboard read (round-trip)");
    roundtrip("__core__", "{\"cmd\":\"clipboard_clear\"}",
              "\"cmd\":\"clipboard_clear\",\"success\":true", "core clipboard clear");
    roundtrip("__core__", "{\"cmd\":\"clipboard_read_text\"}",
              "\"text\":\"\"", "core clipboard read after clear");
    roundtrip("__core__", "{\"cmd\":\"shell_open_external\",\"url\":\"https://suji.dev\"}",
              "\"cmd\":\"shell_open_external\",\"success\":true", "core shell open_external");
    roundtrip("__core__", "{\"cmd\":\"notification_is_supported\"}",
              "\"supported\":true", "core notification is_supported");
    roundtrip("__core__", "{\"cmd\":\"notification_show\",\"title\":\"Hi\",\"body\":\"B\"}",
              "\"notificationId\":\"suji-notif-0\",\"success\":true", "core notification show");
    roundtrip("__core__", "{\"cmd\":\"notification_close\",\"notificationId\":\"suji-notif-0\"}",
              "\"cmd\":\"notification_close\",\"success\":true", "core notification close");
    roundtrip("__core__", "{\"cmd\":\"safe_storage_set\",\"service\":\"s\",\"account\":\"a\",\"value\":\"sekret\"}",
              "\"cmd\":\"safe_storage_set\",\"success\":true", "core safe_storage set");
    roundtrip("__core__", "{\"cmd\":\"safe_storage_get\",\"service\":\"s\",\"account\":\"a\"}",
              "\"value\":\"sekret\"", "core safe_storage get (round-trip)");
    roundtrip("__core__", "{\"cmd\":\"safe_storage_delete\",\"service\":\"s\",\"account\":\"a\"}",
              "\"cmd\":\"safe_storage_delete\",\"success\":true", "core safe_storage delete");
    roundtrip("__core__", "{\"cmd\":\"safe_storage_get\",\"service\":\"s\",\"account\":\"a\"}",
              "\"value\":\"\"", "core safe_storage get after delete");
    roundtrip("__core__", "{\"cmd\":\"app_get_locale\"}",
              "\"locale\":\"en-US\"", "core app_get_locale");
    roundtrip("__core__", "{\"cmd\":\"app_get_name\"}",
              "\"name\":\"SujiMock\"", "core app_get_name");
    roundtrip("__core__", "{\"cmd\":\"app_get_version\"}",
              "\"version\":\"1.0.0\"", "core app_get_version");
    roundtrip("__core__", "{\"cmd\":\"app_get_path\",\"name\":\"documents\"}",
              "\"cmd\":\"app_get_path\",\"path\":\"/mock/docs\"", "core app_get_path");
    roundtrip("__core__", "{\"cmd\":\"clipboard_write_html\",\"html\":\"<b>hi</b>\"}",
              "\"cmd\":\"clipboard_write_html\",\"success\":true", "core clipboard write_html");
    roundtrip("__core__", "{\"cmd\":\"clipboard_read_html\"}",
              "\"html\":\"<b>hi</b>\"", "core clipboard read_html (round-trip)");
    roundtrip("__core__", "{\"cmd\":\"clipboard_write_rtf\",\"rtf\":\"{rtf1 x}\"}",
              "\"cmd\":\"clipboard_write_rtf\",\"success\":true", "core clipboard write_rtf");
    roundtrip("__core__", "{\"cmd\":\"clipboard_read_rtf\"}",
              "\"rtf\":\"{rtf1 x}\"", "core clipboard read_rtf (round-trip)");
    roundtrip("__core__", "{\"cmd\":\"clipboard_write_image\",\"data\":\"UABNAGc=\"}",
              "\"cmd\":\"clipboard_write_image\",\"success\":true", "core clipboard write_image");
    roundtrip("__core__", "{\"cmd\":\"clipboard_read_image\"}",
              "\"data\":\"UABNAGc=\"", "core clipboard read_image (round-trip)");
    roundtrip("__core__", "{\"cmd\":\"fs_write_file\",\"path\":\"/x\",\"text\":\"fsdata\"}",
              "\"cmd\":\"fs_write_file\",\"success\":true", "core fs write_file");
    roundtrip("__core__", "{\"cmd\":\"fs_read_file\",\"path\":\"/x\"}",
              "\"success\":true,\"text\":\"fsdata\"", "core fs read_file (round-trip)");
    roundtrip("__core__", "{\"cmd\":\"fs_readdir\",\"path\":\"/x\"}",
              "\"name\":\"suji-e2e-fs.txt\",\"type\":\"file\"", "core fs readdir");
    roundtrip("__core__", "{\"cmd\":\"clipboard_write_buffer\",\"format\":\"x/y\",\"data\":\"QUJD\"}",
              "\"cmd\":\"clipboard_write_buffer\",\"success\":true", "core clipboard write_buffer");
    roundtrip("__core__", "{\"cmd\":\"clipboard_read_buffer\",\"format\":\"x/y\"}",
              "\"data\":\"QUJD\"", "core clipboard read_buffer (round-trip)");
    roundtrip("__core__", "{\"cmd\":\"clipboard_has\",\"format\":\"x/y\"}",
              "\"present\":true", "core clipboard has");
    roundtrip("__core__", "{\"cmd\":\"clipboard_available_formats\"}",
              "\"formats\":[", "core clipboard available_formats");
    roundtrip("__core__", "{\"cmd\":\"fs_stat\",\"path\":\"/x\"}",
              "\"success\":true,\"type\":\"file\",\"size\":6", "core fs stat");
    roundtrip("__core__", "{\"cmd\":\"fs_mkdir\",\"path\":\"/x\",\"recursive\":true}",
              "\"cmd\":\"fs_mkdir\",\"success\":true", "core fs mkdir");
    roundtrip("__core__", "{\"cmd\":\"fs_rm\",\"path\":\"/x\",\"force\":true}",
              "\"cmd\":\"fs_rm\",\"success\":true", "core fs rm");
    roundtrip("__core__", "{\"cmd\":\"shell_beep\"}",
              "\"cmd\":\"shell_beep\",\"success\":true", "core shell beep");
    roundtrip("__core__", "{\"cmd\":\"shell_trash_item\",\"path\":\"/x\"}",
              "\"cmd\":\"shell_trash_item\",\"success\":false",
              "core shell trash graceful false");
    roundtrip("__core__", "{\"cmd\":\"window_create\"}",
              "\"error\":\"unknown_cmd\"", "core unsupported cmd → coreError 동형");

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
