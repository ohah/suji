# Audit follow-ups — 환경 검증 필요 (블라인드 수정 보류)

전수조사(2026-06)에서 확정됐으나 **로컬(macOS, 헤드리스)에서 검증할 수 없어** 블라인드
수정이 위험하다고 판단해 보류한 항목. 해당 환경에서 적용 후 검증할 것. (검증 가능한
플랫폼/크로스플랫폼 항목은 본 커밋들에서 이미 수정됨.)

---

# A. Windows 전용 (Windows 환경에서 수정·테스트)

Windows 전용 코드라 macOS 빌드에서 comptime-prune 되어 컴파일조차 검증 불가.

## A.1. globalShortcut: `win_gs.slots` 무락 공유 — 데이터 레이스 (low/latent)

- **위치**: `src/platform/cef_global_shortcut.zig` (`win_gs` 네임스페이스, `slots`),
  `src/platform/cef_win_pump.zig:~297` (pump 스레드 WM_HOTKEY read).
- **문제**: `slots`(멀티필드 Slot 배열)를 **IPC 스레드**(register/unregister write)와
  **pump 스레드**(WM_HOTKEY 수신 시 id→click 매핑 read)가 락 없이 공유한다. IPC 스레드가
  slot 을 부분 기록하는 중 pump 스레드가 읽으면 찢긴(half-written) accel/click 을 emit 할
  수 있다. Linux 경로(`cef_global_shortcut_linux.zig`)는 `slots_lock` spinlock 으로 이미
  보호하나 Windows 경로엔 없음.
- **수정 방향**(Linux `slots_lock` 패턴 미러링):
  ```zig
  // win_gs 네임스페이스에 추가
  pub var slots_lock: std.atomic.Value(bool) = .init(false);
  pub fn lockSlots() void {
      while (slots_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
          std.atomic.spinLoopHint();
  }
  pub fn unlockSlots() void { slots_lock.store(false, .release); }
  ```
  - `register`: **slot write 블록(`s.used = true ...`)만** `lockSlots()/defer unlockSlots()`
    로 감쌀 것. ⚠️ `win_pump.submitSync`(pump 스레드를 기다림) 구간엔 절대 락을 잡지 말 것
    — pump 가 같은 락을 원하면 데드락.
  - `unregister` / `unregisterAll`: submitSync **이후** 의 slot 클리어 블록만 보호.
  - `cef_win_pump.zig` WM_HOTKEY 핸들러: `for (&cef_global_shortcut.win_gs.slots)` read
    루프를 `win_gs.lockSlots()/defer win_gs.unlockSlots()` 로 보호.
- **검증**: Windows 빌드 + `tests/e2e/run-global-shortcut.sh`(가능 시 동시 register/trigger
  스트레스).

> 참고: 같은 감사에서 나온 PowerShell `Expand-Archive` single-quote 이스케이프
> (`prepareWindowsZip`)와 POSIX quit-install PID 상한은 cross-platform 으로 컴파일되어
> 본 커밋에 포함됨(Windows 런타임 동작은 CI 가 가드). 이 문서는 **컴파일 자체가 macOS
> 에서 불가능한** Windows-only 항목만 다룬다.

---

# B. 실 TLS/auth 환경 검증 필요 (`cef_auth_handler.zig`, 헤드리스 불가)

`app:certificate-error`/`app:login`/`app:select-client-certificate` 는 CEF
request_handler **deferred 콜백**으로, 실 TLS 에러/basic auth/client cert 검증은
헤드리스에서 트리거 불가(파일 헤더 명시 — "빌드+wire 검증 정직 경계"). held CEF 콜백
ref 를 다루므로 잘못 고치면 double-respond/UAF 위험이 커, 실 환경 검증 전엔 보류.
(같은 감사의 escape 버퍼 overflow→silent fallback[#2]·client-cert 16개 절단[#3]은
저위험이라 본 커밋에서 수정: escape 버퍼를 입력 최악 6배로 확장, MAX_CERTS 16→32 +
`totalCertCount` 통지.)

## B.1. deferred 콜백 navigation/browser-close 정리 부재 (low/memory)

- **문제**: `g_cert`/`g_auth`/`g_client` pending pool 의 held 콜백은 사용자가 응답하기
  전에 **창이 닫히거나 navigation 이 일어나면** 정리되지 않아 CEF 콜백 ref 가 누수될 수
  있다. `cef_session_permission` 은 `onDismissPermissionPrompt` 로 정리 경로가 있으나
  auth 엔 없음.
- **구조 변경 필요**: 현재 `PendingClientCert`/cert/auth 엔트리는 `browser_handle` 을
  추적하지 않아 browser 단위 purge 가 불가. 먼저 각 pending 구조체에 `browser_handle`
  필드를 추가(핸들러 인자 `browser` 에서 채움)하고, `cef_life_span_handler` 의
  `onBeforeClose` 에서 `purgeForBrowser(handle)` 를 호출해 해당 browser 의 held 콜백을
  `*ReleaseOnly`(respond 없이 ref 해제)로 정리하는 경로를 추가할 것.
- **검증**: 실 TLS 클라이언트-cert/auth 다이얼로그 + 응답 전 창 닫기 → ref leak 부재.

## B.2. `setAuthHandlerEnabled(false)` 콜백 hold 중 호출 시 영구 hold (medium/dos)

- **문제**: 콜백이 pending 인 동안 `setAuthHandlerEnabled(false)` 를 호출하면 이미
  hold 된 콜백이 정리되지 않아 영구 hold(렌더러/네트워크 무한 대기) 된다.
- **수정 방향**: `setAuthHandlerEnabled(false)` 내부에서 3 pool(`g_cert`/`g_auth`/
  `g_client`)을 순회하며 각 엔트리를 **atomic take**(`certTake`/`authTake`/`clientTake`)
  후 안전한 기본으로 resolve — cert=cont(false)=차단, auth=cancel, client-cert=
  select(null). atomic take 가 실 응답 경로와의 double-respond 를 막지만(take 된 뒤엔
  앱의 respond 가 no-op), 실 콜백 동시성은 헤드리스에서 재현 불가하므로 실 환경에서
  검증 후 적용할 것.
- **검증**: 실 auth 다이얼로그 hold 중 disable → 콜백이 기본값으로 settle, 누수/행 부재.
