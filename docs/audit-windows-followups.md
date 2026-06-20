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

---

# C. 코드리뷰(max)에서 식별된 잔여 설계 한계 (재설계 필요, 본 스윕 범위 밖)

전수조사 수정에 대한 `/code-review max` 가 확인했으나, 올바른 수정이 기존 메커니즘의
재설계를 요구해 본 커밋 범위 밖으로 둔 항목. (리뷰가 잡은 **실제 버그**—lua id==0 UAF,
shell file:// 게이트 회귀, canonicalizePath overflow, coreInvoke embed current_invoker,
embed 모바일 file://—는 모두 수정됨.)

## C.1. page_output 극단 엣지의 deferred Promise hang (low, 거의 도달 불가)

- **문제**: `handlePrintToPDF`/`handleCapturePage`(window_ipc)는 `wm.printToPDF`/
  `capturePage` 를 **호출한 뒤** deferred(cefDeferResponse)를 등록한다. 따라서
  printToPDF/capturePage 가 **동기적으로 실패**(path 초과·CEF host 기능 미지원·pending
  풀 16 동시)하는 극단 엣지에서, 그 시점엔 deferred 슬롯이 아직 없어 동기 emit 으로
  resolve 할 수 없고(스퓨리어스 이벤트만), 이후 핸들러는 `ok=true` 로 보고 defer 해
  Promise 가 영구 hang 한다.
- **올바른 수정(altitude)**: `print_to_pdf`/`capture_page` **vtable 시그니처에 "async
  시작 여부" bool 을 전파**해, 시작 못 했으면 `wm.*` 가 error 를 반환 → 핸들러가 즉시
  `respondWindowOp(false)` 로 실패 응답(defer 안 함). vtable 구현체(CEF + 테스트 mock)를
  함께 바꿔야 한다. 엣지가 CEF 표준에선 도달 불가라 우선순위 낮음.

## C.2. EventBusSink 콜백-내 교차 리스너 ctx UAF (events.zig 와 동일 패턴)

- **문제**: `invokeCancelable` 콜백 A 가 같은 스레드에서 `offCancelable(B.id)` 호출 →
  `sink_in_dispatch=true` 라 quiescence 대기를 건너뜀(자기-대기 데드락 회피용) → 호출자가
  B.ctx 를 free → 스냅샷의 B 콜백이 freed ctx 로 발화 → UAF. **`events.zig` EventBus 의
  `in_dispatch` 패턴과 동일**(본 PR 의 event_sink 배리어는 그 패턴을 일관 적용한 것).
- **정직 경계**: 실제로 cancelable 리스너(window:close)는 콜백 안에서 서로의 ctx 를
  free 하지 않아 트리거되지 않는다(이론적). 근본 수정은 콜백-내 동기 free 금지(deferred
  free) 또는 ctx refcount — events.zig 와 함께 일괄 재설계해야 한다.

## C.3. 핫 리로드 후 충돌-센티널("") 채널 영구 차단 (충돌 추적 부재)

- **문제**: 두 백엔드가 같은 채널을 등록하면 `coreRegister` 가 routes 값을 ""(auto-route
  disabled)로 둔다. 한 백엔드가 reload 하면 `clearRoutesFor` 가 그 백엔드의 엔트리만
  제거하고 "" 센티널은 남긴다 — 그 채널을 reload 후 더는 충돌하지 않는데도 "" 가 남아
  자동 라우팅이 영구 차단될 수 있다(reload 한 백엔드가 그 채널을 드롭한 경우).
- **정직 경계**: 대부분은 충돌이 *여전히 유효*(다른 백엔드가 계속 등록)해 "" 유지가
  **올바른** 동작이다. 문제 케이스(충돌 후 reload + 채널 드롭)는 좁고, 올바른 수정은
  routes 가 충돌 *참여 백엔드 집합*을 추적해 마지막 하나 남으면 복원하는 재설계를 요구.
  본 PR 은 비-충돌 채널의 reload 라우팅(주 버그)을 고쳤다.

## C.4. PDF 인쇄 cross-window 동일-path 상관 (글로벌 콜백 제약)

- **문제**: capturePage 는 완료 시 `browser_handle` 을 알아 cross-window 오라우팅을 막지만
  (본 PR 수정), PDF 인쇄 완료 콜백(`onPdfPrintFinished`)은 **글로벌 stateless** 라
  browser_handle 을 모른다 → `cefCompletePending(.print, 0, …)` 로 (kind,path) 만 매칭.
  서로 다른 창에서 동일 path 로 동시 PDF 요청 시 첫 완료가 엉뚱한 창 Promise 를 resolve.
- **정직 경계**: CLAUDE.md "알려진 이슈" 의 deferred-response 동일-path 상관 한계와 동일
  계열(per-call ref-counted CEF 콜백 수명 관리 필요 — 비용 대비 가치 낮아 의도적 미수정).
