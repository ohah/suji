# SDK Porting Guide

새 언어로 Suji 백엔드 SDK를 작성하는 가이드. **체크리스트로 누락 없이 포팅**하기 위한 표준 명세 — 현재 Zig/Rust/Go/Node가 모두 따르는 패턴이며, Python/Ruby 등 신규 SDK도 같은 표면을 노출해야 한다.

> **이 문서를 업데이트할 시점:** core IPC에 새 cmd가 추가되거나(`window_ipc.zig`), `SujiCore` C ABI vtable이 변경될 때. 5개 SDK가 동시에 일관성 깨지지 않도록.

---

## 1. 백엔드 모델

Suji 백엔드는 두 가지 모델 중 하나로 동작한다:

| 모델 | 설명 | 예 |
|------|------|----|
| **dlopen dylib** | Suji core가 `dlopen`으로 cdylib 로드. C ABI 4개 함수(`backend_init/handle_ipc/free/destroy`) export | Zig, Rust, Go |
| **embed runtime** | core 안에 언어 런타임이 embed되어 있고, core가 직접 호출. C++/N-API bridge | Node.js (libnode 임베드) |

두 모델 모두 **`SujiCore` C ABI vtable**을 통해 코어와 통신한다. dlopen 백엔드는 `backend_init(*const SujiCore)`로 받고, embed runtime은 코어가 직접 inject.

---

## 2. SujiCore C ABI (코어가 SDK에 제공)

`src/backends/loader.zig:7` `pub const SujiCore = extern struct`:

```c
typedef struct SujiCore {
    const char* (*invoke)(const char* backend, const char* request);
    void        (*free)(const char* response);
    void        (*emit)(const char* channel, const char* data);
    uint64_t    (*on)(const char* channel, void (*cb)(const char*, const char*, void*), void* arg);
    void        (*off)(uint64_t listener_id);
    void        (*register)(const char* channel);
    const void* (*get_io)(void);                   // Zig 전용
    void        (*quit)(void);
    const char* (*platform)(void);                  // 0-term "macos"|"linux"|"windows"
    void        (*emit_to)(uint32_t window_id, const char* channel, const char* data);
} SujiCore;
```

- **모든 문자열은 0-terminated UTF-8.**
- `invoke` 응답은 SDK가 free 안 함 — Suji core가 자기 allocator로 관리. SDK는 **즉시 사본을 만든 뒤** 반환된 포인터 수명에 의존하지 말 것.
- `on` 콜백은 코어 스레드(CEF UI 스레드)에서 호출됨 — SDK가 자체 스레드/event loop으로 옮겨야 안전.

---

## 3. dlopen 백엔드 — SDK가 export해야 하는 4개 함수

Suji core가 `dlopen` 후 lookup하는 심볼:

```c
// 1. core 주입 (1회). NULL 가능 (테스트 환경 등)
void backend_init(const SujiCore* core);

// 2. IPC 요청 처리. 응답은 SDK가 alloc — backend_free로 해제됨.
char* backend_handle_ipc(const char* request_json);

// 3. backend_handle_ipc 응답 메모리 해제.
void backend_free(char* response);

// 4. 종료 시 cleanup (closer/listener/runtime 정리)
void backend_destroy(void);
```

(embed runtime은 다른 entrypoint를 가짐 — Node는 `EmbedRuntime` 테이블 참고.)

---

## 4. SDK가 노출해야 하는 사용자 API

각 언어의 idiom에 맞게 네이밍하되 **기능 1:1 매핑** 유지.

### 4.1 핵심 IPC

| 기능 | Zig | Rust | Go | Node | 설명 |
|------|-----|------|----|----- |------|
| 핸들러 등록 | `app().handle("ch", fn)` | `#[suji::handle]` macro | `suji.Bind(&App{})` reflect | `handle('ch', fn)` | 채널명 → 함수 |
| 핸들러 호출 (다른 BE) | `Request.invoke(backend, req)` | `suji::invoke(backend, req)` | `suji.Invoke(backend, req)` | `invoke(backend, req)` async / `invokeSync` | core.invoke 래퍼 |
| 이벤트 발신 (broadcast) | `suji.send(ch, data)` | `suji::send(ch, data)` | `suji.Send(ch, data)` | `send(ch, data)` | core.emit |
| 이벤트 발신 (특정 창) | `suji.sendTo(id, ch, data)` | `suji::send_to(id, ch, data)` | `suji.SendTo(id, ch, data)` | `sendTo(id, ch, data)` | core.emit_to |
| 이벤트 수신 | `app().on("ch", fn)` | `suji::on(ch, cb, arg)` | `suji.On(ch, cb)` | `on(ch, fn)` | core.on |
| 리스너 해제 | (자동) | `suji::off(id)` | `suji.Off(id)` | `off(subId)` | core.off |
| 채널 등록 | (handle이 자동) | (macro가 자동) | (Bind가 자동) | `register(ch)` | core.register |
| 종료 | `suji.quit()` | `suji::quit()` | `suji.Quit()` | `quit()` | core.quit |
| 플랫폼 | `suji.platform()` | `suji::platform()` | `suji.Platform()` | `platform()` | core.platform |

### 4.2 InvokeEvent (Phase 2.5)

핸들러 시그니처에 두 번째 파라미터로 `InvokeEvent` (Electron `IpcMainInvokeEvent` 대응). wire JSON의 `__window` / `__window_name` / `__window_url` / `__window_main_frame` 4개 필드에서 파생.

```ts
interface InvokeEvent {
  window: {
    id: number;          // __window
    name: string | null; // __window_name (익명 창은 null)
    url: string | null;  // __window_url (sender main frame URL)
    isMainFrame: boolean | null; // __window_main_frame
  };
}
```

각 SDK가 1-arity와 2-arity 핸들러를 모두 지원하도록 **정확히 한 가지 분기 메커니즘**을 사용:
- **Zig:** comptime fn 시그니처 reflection
- **Rust:** proc-macro가 파라미터 타입 보고 자동 주입
- **Go:** `reflect`로 마지막 파라미터가 `*InvokeEvent`인지 검사
- **Node:** `handler.length` (1 vs 2)
- **Python (예정):** `inspect.signature` 파라미터 수
- **Ruby (예정):** `Method#arity`

### 4.3 windows API (Phase 4-A/B/C/E)

**모든 SDK가 동일한 cmd JSON을 `invoke("__core__", ...)`로 전송** — 코어의 `cefHandleCore`가 dispatch한다 (`src/main.zig:1014`).

#### Phase 4-A 네비/JS

| 기능 | cmd | 필드 | 응답 형식 |
|------|-----|------|----------|
| 새 창 생성 | `create_window` | `title?, url?, name?, width?, height?, x?, y?, parentId?, parent?, frame?, transparent?, backgroundColor?, titleBarStyle?, resizable?, alwaysOnTop?, minWidth?, minHeight?, maxWidth?, maxHeight?, fullscreen?` | `{from, cmd, windowId}` |
| 타이틀 변경 | `set_title` | `windowId, title` | `{from, cmd, windowId, ok}` |
| 크기/위치 | `set_bounds` | `windowId, x, y, width, height` | `{from, cmd, windowId, ok}` |
| URL 로드 | `load_url` | `windowId, url` | `{from, cmd, windowId, ok}` |
| reload | `reload` | `windowId, ignoreCache` | `{from, cmd, windowId, ok}` |
| JS 실행 | `execute_javascript` | `windowId, code` | `{from, cmd, windowId, ok}` (fire-and-forget) |
| URL 조회 | `get_url` | `windowId` | `{from, cmd, windowId, ok, url}` (캐시 미스 시 url=null) |
| 로딩 중인지 | `is_loading` | `windowId` | `{from, cmd, windowId, ok, loading}` |

#### Phase 4-B 줌 (Electron 호환 — factor=pow(1.2, level))

| cmd | 필드 | 응답 |
|-----|------|------|
| `set_zoom_level` | `windowId, level` | `{..., ok}` |
| `set_zoom_factor` | `windowId, factor` | `{..., ok}` |
| `get_zoom_level` | `windowId` | `{..., ok, level}` |
| `get_zoom_factor` | `windowId` | `{..., ok, factor}` |

#### Phase 4-C DevTools

| cmd | 필드 | 응답 |
|-----|------|------|
| `open_dev_tools` | `windowId` | `{..., ok}` (이미 열림이면 멱등 no-op) |
| `close_dev_tools` | `windowId` | `{..., ok}` |
| `is_dev_tools_opened` | `windowId` | `{..., ok, opened}` |
| `toggle_dev_tools` | `windowId` | `{..., ok}` |

#### Phase 4-E 편집/검색

| cmd | 필드 | 응답 |
|-----|------|------|
| `undo` / `redo` / `cut` / `copy` / `paste` / `select_all` | `windowId` | `{..., ok}` (frame 위임) |
| `find_in_page` | `windowId, text, forward, matchCase, findNext` | `{..., ok}` (결과 보고는 추후 이벤트) |
| `stop_find_in_page` | `windowId, clearSelection` | `{..., ok}` |

새 SDK는 위 cmd를 모두 typed wrapper로 노출한다. **JSON-safe escape는 SDK 책임** — 사용자가 raw `"`, `\\`, control char 들어간 문자열을 넘겨도 wire JSON이 깨지지 않아야 한다 (구현 패턴: `escape_json` 헬퍼 — `"` → `\"`, `\\` → `\\\\`, `< 0x20` drop).

### 4.4 명명 규칙

| 언어 | 패키지/모듈 | 함수 이름 | 옵션 객체 |
|------|------------|----------|----------|
| Zig | `suji.windows` | `loadURL`, `reload`, `executeJavaScript`, ... | struct (snake_case fields) |
| Rust | `suji::windows` | `load_url`, `reload`, `execute_javascript`, ... | struct (snake_case fields) |
| Go | `windows` (sub-package, `import "github.com/ohah/suji-go/windows"`) | `LoadURL`, `Reload`, `ExecuteJavaScript`, ... | struct (PascalCase fields) |
| Node | `suji.windows.*` | `loadURL`, `reload`, `executeJavaScript`, ... | object literal (camelCase) |
| Python (예정) | `suji.windows` | `load_url`, `reload`, `execute_javascript`, ... | dict 또는 dataclass |
| Ruby (예정) | `Suji::Windows` | `load_url`, `reload`, `execute_javascript`, ... | Hash 또는 Struct |

**JSON wire 키는 항상 camelCase** (suji.json schema와 일치). Python/Ruby의 snake_case는 SDK 안에서 변환.

---

## 5. 새 SDK 포팅 체크리스트

신규 언어 X SDK를 작성할 때 완료해야 할 항목:

### 5.1 dlopen/embed bridge
- [ ] `backend_init(SujiCore*)` 받아서 모듈 전역에 저장 (또는 embed 경로 셋업)
- [ ] `backend_handle_ipc(req)` — 등록된 핸들러 dispatch + 응답 alloc
- [ ] `backend_free(resp)` — backend_handle_ipc 응답 해제
- [ ] `backend_destroy()` — listener/runtime cleanup

### 5.2 핵심 IPC API (4.1 표)
- [ ] `invoke / send / sendTo / on / off / register / quit / platform`
- [ ] `handle` 등록 (1-arity와 2-arity 둘 다 지원)
- [ ] InvokeEvent 자동 주입 (`__window` / `__window_name` / `__window_url` / `__window_main_frame` 파싱)

### 5.3 windows API (4.3 표)
- [ ] `create / setTitle / setBounds / loadURL / reload / executeJavaScript / getURL / isLoading` 8개 cmd
- [ ] `escape_json` 헬퍼 — `"`, `\\`, control char 처리

### 5.4 테스트
- [ ] 단위: handle 등록/dispatch, InvokeEvent 파싱, escape_json 엣지 케이스
- [ ] 단위: windows.* 가 올바른 cmd JSON으로 변환되는지 (invoke spy)
- [ ] examples/X-backend/: 빈 cdylib 빌드 + suji dev 시 시작 → 종료
- [ ] e2e: tests/e2e의 cef-ipc / window-injection / window-lifecycle 시나리오 통과 (cross-language chain 호출 포함)

### 5.5 빌드 통합
- [ ] Suji core CLI(`suji init`)에 X 템플릿 추가
- [ ] `suji build` / `suji dev`에서 X cdylib 빌드 명령 통합
- [ ] CI 매트릭스에 macOS/Linux/Windows X 빌드 추가

### 5.6 문서
- [ ] `CLAUDE.md` 코드 예제 섹션에 X 추가
- [ ] examples/X-backend/ + examples/multi-backend/backends/X 추가
- [ ] 본 문서(SDK_PORTING.md)의 4.4 명명 규칙 표에 X 행 추가

---

## 6. 참고 구현 위치

| 언어 | 위치 | invoke wrapper | windows API |
|------|------|---------------|-------------|
| Zig | `src/core/app.zig` | `callBackend` (L591) | `pub const windows = struct {...}` (L478) |
| Rust | `crates/suji-rs/src/lib.rs` | `pub fn invoke` (L101) | `pub mod windows {...}` (L154) |
| Go | `sdks/suji-go/export.go` | `func Invoke` (L61) | `sdks/suji-go/windows/windows.go` (sub-package) |
| Node | `packages/suji-node/src/index.ts` | `export async function invoke` (L128) | `export const windows = {...}` (말미) |
| Frontend JS | `packages/suji-js/src/index.ts` | `getBridge().core(...)` | `export const windows = {...}` |

코어 IPC 라우팅: `src/main.zig:cefHandleCore` (L1014) — 새 cmd 추가 시 여기 분기 + `src/core/window_ipc.zig`에 핸들러.

---

## 7. 미해결 / V2 예정

- **Python embed runtime** — 현재 dlopen만. Python은 GIL/thread 모델 때문에 embed가 자연. `EmbedRuntime` 테이블에 등록.
- **Ruby embed runtime** — 동일.
- **`SujiCore.get_window_api`** — 플러그인이 BrowserWindow를 직접 조작 (현재는 invoke `__core__` 경유만). Phase 4 후반에 도입.
- **테스트 spy 표준화** — 현재 각 SDK가 invoke spy를 자체 구현. 공통 패턴 문서화 또는 reusable harness 검토.
