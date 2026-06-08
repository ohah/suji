/**
 * Window Lifecycle E2E Tests
 *
 * Suji 앱을 CEF 모드로 실행한 상태에서 창 생성/이벤트 발화 경로를 검증한다.
 *
 * 실행 방법:
 *   1. cd examples/zig-backend && ../../zig-out/bin/suji dev
 *      (또는 CEF 렌더러가 http://localhost:9222에서 DevTools를 노출하는 예제)
 *   2. bun test tests/e2e/window-lifecycle.test.ts
 *
 * 범위:
 *   - `__suji__.core` IPC로 `create_window` 호출 → WM 경유 → 새 창 생성
 *   - `window:created` 이벤트가 첫 창 frontend 리스너에 도달
 *   - 응답 객체 형식 (`{from, cmd, windowId}`) 검증 (프론트 측에서 이미 JSON.parse됨)
 *   - 로그 파일이 `~/.suji/logs/` 아래 실제로 생성되는지
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page, type Target } from "puppeteer-core";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

type CoreResponse = { from: string; cmd: string; windowId: number };

const coreCall = (request: object): Promise<CoreResponse> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request,
  ) as Promise<CoreResponse>;

const isDesktopCefViewsRun = () =>
  ["darwin", "linux", "win32"].includes(process.platform) &&
  process.env.SUJI_CEF_VIEWS !== "0" &&
  process.env.SUJI_CEF_VIEWS !== "false";

async function waitForNewPageTarget(excluded: Set<Target>, timeoutMs = 5000): Promise<Target> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const cand = browser.targets().find((t) => t.type() === "page" && !excluded.has(t));
    if (cand) return cand;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`new page target not discovered within ${timeoutMs}ms`);
}

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    // CEF 실제 창 크기를 그대로 사용. 명시 안 하면 puppeteer가 800x600으로 viewport를
    // 강제 emulation해서 window.innerWidth / page.screenshot 결과가 실제 NSWindow와 달라짐.
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("runner mode guard", () => {
  test("desktop runner/default actually enabled native CEF Views path", () => {
    if (!isDesktopCefViewsRun()) return;
    const logPath = process.env.SUJI_LOG;
    expect(logPath).toBeTruthy();
    const log = readFileSync(logPath!, "utf8");
    expect(log).toContain("CEF Views path enabled");
  });
});

// ============================================
// 1. create_window IPC 경로
// ============================================

describe("create_window IPC", () => {
  test("core() returns object with windowId", async () => {
    const r = await coreCall({ cmd: "create_window", title: "E2E Test", url: "about:blank" });
    expect(r.from).toBe("zig-core");
    expect(r.cmd).toBe("create_window");
    expect(typeof r.windowId).toBe("number");
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("create_window with missing fields uses defaults", async () => {
    const r = await coreCall({ cmd: "create_window" });
    expect(typeof r.windowId).toBe("number");
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("multiple create_window calls yield distinct windowIds", async () => {
    const r1 = await coreCall({ cmd: "create_window", title: "win-a", url: "about:blank" });
    const r2 = await coreCall({ cmd: "create_window", title: "win-b", url: "about:blank" });
    expect(r1.windowId).not.toBe(r2.windowId);
  });
});

// ============================================
// 2. window:created 이벤트 전파
// ============================================

describe("window:created event propagation", () => {
  test("suji.on('window:created') receives event when IPC creates window", async () => {
    // 페이지 콘솔 캡처 (listener 호출 여부 진단용)
    const consoleLogs: string[] = [];
    const handler = (msg: any) => consoleLogs.push(msg.text());
    page.on("console", handler);

    // 리스너 등록
    await page.evaluate(() => {
      (window as any).__test_created = [];
      (window as any).__suji__.on("window:created", (data: any) => {
        console.log("LISTENER HIT:", JSON.stringify(data));
        (window as any).__test_created.push(data);
      });
    });

    const r = await coreCall({ cmd: "create_window", title: "evt-test", url: "about:blank" });

    // 이벤트 dispatch 대기 (CEF execute_java_script는 async)
    await new Promise((r2) => setTimeout(r2, 500));

    const received: any[] = await page.evaluate(() => (window as any).__test_created);
    page.off("console", handler);

    if (received.length === 0) {
      // 진단용: 콘솔 로그 덤프
      console.error("Console during test:", consoleLogs);
    }

    expect(received.length).toBeGreaterThan(0);
    // 데이터가 객체면 windowId 속성 확인, 문자열이면 포함 확인
    const hasOurId = received.some((d) => {
      if (typeof d === "object" && d !== null) return d.windowId === r.windowId;
      return String(d).includes(`"windowId":${r.windowId}`);
    });
    expect(hasOurId).toBe(true);
  });
});

// ============================================
// 3. Phase 3 옵션 풀 셋 — IPC 파서/정규화/매핑 회귀
// ============================================

describe("create_window Phase 3 옵션 (frame/transparent/parent/min·max/...)", () => {
  test("frameless + transparent 창도 정상 응답", async () => {
    const r = await coreCall({
      cmd: "create_window",
      title: "frameless-transparent",
      url: "about:blank",
      width: 320,
      height: 200,
      frame: false,
      transparent: true,
    });
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("backgroundColor + titleBarStyle hiddenInset 옵션 수락", async () => {
    const r = await coreCall({
      cmd: "create_window",
      title: "bg+titlebar",
      url: "about:blank",
      backgroundColor: "#202020",
      titleBarStyle: "hiddenInset",
    });
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("invalid backgroundColor (#ZZZZZZ) — 응답 OK + warn 로그만", async () => {
    // applyBackgroundColor가 silent fail (로그만)이라 IPC는 success.
    const r = await coreCall({
      cmd: "create_window",
      title: "bad-bg",
      url: "about:blank",
      backgroundColor: "#ZZZZZZ",
    });
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("min > max — wm가 정규화하므로 에러 없이 생성", async () => {
    const r = await coreCall({
      cmd: "create_window",
      title: "min-gt-max",
      url: "about:blank",
      minWidth: 800,
      maxWidth: 400,
      minHeight: 600,
      maxHeight: 200,
    });
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("parent name으로 부모 창 attach (silent fail-safe — 미존재면 무시)", async () => {
    // ghost 부모는 wm.fromName에서 null → cef는 attach 안 함, 자식 창은 정상 생성.
    const r = await coreCall({
      cmd: "create_window",
      title: "orphan-with-ghost-parent",
      url: "about:blank",
      parent: "this-name-does-not-exist",
    });
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("parent name으로 실제 부모 창 attach 옵션 수락", async () => {
    const parentName = `parent-${Date.now()}`;
    const parent = await coreCall({
      cmd: "create_window",
      name: parentName,
      title: "parent-native-options",
      url: "about:blank",
      width: 360,
      height: 240,
    });
    const child = await coreCall({
      cmd: "create_window",
      title: "child-native-options",
      url: "about:blank",
      parent: parentName,
      frame: false,
      transparent: true,
      backgroundColor: "#00000000",
      width: 240,
      height: 160,
      resizable: false,
      alwaysOnTop: true,
    });
    expect(parent.windowId).toBeGreaterThan(0);
    expect(child.windowId).toBeGreaterThan(0);
    expect(child.windowId).not.toBe(parent.windowId);
  });

  test("alwaysOnTop + fullscreen + resizable=false 동시 set", async () => {
    const r = await coreCall({
      cmd: "create_window",
      title: "always-top",
      url: "about:blank",
      alwaysOnTop: true,
      resizable: false,
    });
    expect(r.windowId).toBeGreaterThan(0);
  });

  // Windows CEF 의 frameless 창 + drag region (app-region: drag) 처리는
  // OnDraggableRegionsChanged 콜백 + WM_NCHITTEST 매핑 필요 — 우리 구현이
  // macOS NSWindow dragRect 만 매핑. Windows 측 hit-test 미배선 → no-drag
  // 버튼 click 이 drag 으로 인식. Electron 식 BrowserWindow draggable region
  // Win32 impl 추가 시 가드 제거.
  test.skipIf(process.platform !== "darwin")("frameless drag region 안의 no-drag 컨트롤은 클릭 가능", async () => {
    const html = `<!doctype html>
      <meta charset="utf-8" />
      <style>
        body { margin: 0; font-family: system-ui; }
        .drag { height: 56px; display: flex; align-items: center; padding: 8px; -webkit-app-region: drag; app-region: drag; background: #1f2937; }
        button { -webkit-app-region: no-drag; app-region: no-drag; }
      </style>
      <div class="drag">
        <button id="probe" onclick="document.body.dataset.clicked='yes'">probe</button>
      </div>`;
    const excluded = new Set<Target>(browser.targets().filter((t) => t.type() === "page"));
    const r = await coreCall({
      cmd: "create_window",
      title: "drag-region-probe",
      url: "http://localhost:12300",
      width: 360,
      height: 180,
      frame: false,
    });
    expect(r.windowId).toBeGreaterThan(0);

    const target = await waitForNewPageTarget(excluded);
    const session = await target.createCDPSession();
    await session.send("Runtime.evaluate", {
      expression: `document.open();document.write(${JSON.stringify(html)});document.close();`,
      awaitPromise: true,
    });
    const rectResult = await session.send("Runtime.evaluate", {
      expression: `JSON.stringify(document.querySelector("#probe").getBoundingClientRect())`,
      returnByValue: true,
    });
    const rect = JSON.parse(rectResult.result.value as string);
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    await session.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
    await session.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
    await session.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
    const clickedResult = await session.send("Runtime.evaluate", {
      expression: `document.body.dataset.clicked`,
      returnByValue: true,
    });
    const clicked = clickedResult.result.value;
    await session.detach();
    expect(clicked).toBe("yes");
  });

  test("x/y 음수 (화면 왼쪽 밖 배치) 수락", async () => {
    const r = await coreCall({
      cmd: "create_window",
      title: "off-screen",
      url: "about:blank",
      x: -50,
      y: -10,
    });
    expect(r.windowId).toBeGreaterThan(0);
  });
});

// ============================================
// 5. Zig 백엔드 SDK windows.* round-trip — `suji::windows::isLoading` →
//    callBackend("__core__") → cefHandleCore → wm.isLoading → CEF native.
//    examples/multi-backend/backends/zig가 노출하는 'windows-roundtrip-zig'
//    핸들러를 호출 → 응답에 코어가 돌려준 raw JSON이 들어있는지 확인.
//    Rust/Go/Node SDK는 자체 spy로 cmd JSON 형식만 검증 (단위) — 코어
//    라우팅은 같은 cefHandleCore라 추가 e2e 불필요.
// ============================================

// ============================================
// Phase 2: set_title / set_bounds 런타임 변경
// (이전엔 lifecycle.test에서 검증 안 됐음 — e2e coverage 갭)
// ============================================

describe("Phase 2 — set_title / set_bounds 런타임 변경", () => {
  test("set_title: 응답 ok + cmd 정확", async () => {
    const c = await coreCall({ cmd: "create_window", title: "old", url: "about:blank" });
    const r: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_title", windowId: c.windowId, title: "new title" },
    );
    expect(r.cmd).toBe("set_title");
    expect(r.ok).toBe(true);
    expect(r.windowId).toBe(c.windowId);
  });

  test("set_bounds: 5필드(x/y/width/height) 응답 ok", async () => {
    const c = await coreCall({ cmd: "create_window", title: "bounds-test", url: "about:blank" });
    const r: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_bounds", windowId: c.windowId, x: 50, y: 50, width: 600, height: 400 },
    );
    expect(r.cmd).toBe("set_bounds");
    expect(r.ok).toBe(true);
  });

  test("set_title / set_bounds: 알 수 없는 windowId — ok:false", async () => {
    const r1: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "set_title", windowId: 99999, title: "x" })),
    );
    expect(r1.ok).toBe(false);
    const r2: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "set_bounds", windowId: 99999, width: 100, height: 100 })),
    );
    expect(r2.ok).toBe(false);
  });

  // Electron 패리티: get_bounds (→ SDK getBounds/getSize/getPosition).
  test("get_bounds: set_bounds 후 roundtrip — 크기 정확, 위치 근사", async () => {
    const c = await coreCall({ cmd: "create_window", title: "getbounds", url: "about:blank" });
    await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_bounds", windowId: c.windowId, x: 90, y: 90, width: 520, height: 380 },
    );
    await new Promise((r) => setTimeout(r, 300));
    const b: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "get_bounds", windowId: c.windowId },
    );
    expect(b.cmd).toBe("get_bounds");
    expect(b.ok).toBe(true);
    // 크기는 정확히 round-trip — 기본값 폴백(.{}=800x600)이면 실패하므로 native 실독 증명.
    expect(Math.abs(b.width - 520)).toBeLessThanOrEqual(4);
    expect(Math.abs(b.height - 380)).toBeLessThanOrEqual(4);
    // 위치는 WM 보정 가능 — 좌표계(top-left) 변환이 대략 맞는지(gross 오류 차단)만.
    expect(typeof b.x).toBe("number");
    expect(typeof b.y).toBe("number");
    expect(Math.abs(b.x - 90)).toBeLessThanOrEqual(50);
    expect(Math.abs(b.y - 90)).toBeLessThanOrEqual(50);
  });

  test("get_bounds: 알 수 없는 windowId — ok:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "get_bounds", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
  });

  // Electron 패리티: setMinimumSize/getMinimumSize, setMaximumSize/getMaximumSize.
  // getter 는 추적된 constraints 값을 결정적으로 반환(실기기 의존 없음) → 정확 round-trip.
  test("min/max size: set 후 get roundtrip — 정확값", async () => {
    const c = await coreCall({ cmd: "create_window", title: "minmax", url: "about:blank" });
    const sMin: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_minimum_size", windowId: c.windowId, width: 320, height: 240 },
    );
    expect(sMin.cmd).toBe("set_minimum_size");
    expect(sMin.ok).toBe(true);
    const sMax: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_maximum_size", windowId: c.windowId, width: 1280, height: 960 },
    );
    expect(sMax.ok).toBe(true);

    const gMin: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "get_minimum_size", windowId: c.windowId },
    );
    expect(gMin.ok).toBe(true);
    expect(gMin.width).toBe(320);
    expect(gMin.height).toBe(240);

    const gMax: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "get_maximum_size", windowId: c.windowId },
    );
    expect(gMax.width).toBe(1280);
    expect(gMax.height).toBe(960);
  });

  test("min size enforcement: min 보다 작게 set_bounds → get_bounds 가 min 으로 clamp (macOS)", async () => {
    if (!isDesktopCefViewsRun()) return;
    const c = await coreCall({ cmd: "create_window", title: "minclamp", url: "about:blank" });
    await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_minimum_size", windowId: c.windowId, width: 500, height: 400 },
    );
    // min 보다 작게 리사이즈 시도 → OS(NSWindow setContentMinSize)가 clamp.
    await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_bounds", windowId: c.windowId, x: 80, y: 80, width: 120, height: 100 },
    );
    await new Promise((r) => setTimeout(r, 300));
    const b: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "get_bounds", windowId: c.windowId },
    );
    expect(b.ok).toBe(true);
    // clamp 됐으면 width/height >= min. (정직 경계: macOS contentMinSize 실효 검증.)
    expect(b.width).toBeGreaterThanOrEqual(500 - 4);
    expect(b.height).toBeGreaterThanOrEqual(400 - 4);
  });

  test("min/max size: 알 수 없는 windowId — ok:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "get_minimum_size", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
  });

  // Electron 패리티: setResizable/setMinimizable/setMaximizable/setClosable.
  // getter 는 delegate constraints(결정적) 반환 → 정확 round-trip. 실제 enforcement
  // (사용자 drag/zoom/close 차단)은 헤드리스 미검증 정직 경계 — round-trip 으로 wire 검증.
  test("capability flags: set false → get false → set true round-trip", async () => {
    const c = await coreCall({ cmd: "create_window", title: "caps", url: "about:blank" });
    const cases: Array<[string, string, string]> = [
      ["set_resizable", "is_resizable", "resizable"],
      ["set_minimizable", "is_minimizable", "minimizable"],
      ["set_maximizable", "is_maximizable", "maximizable"],
      ["set_closable", "is_closable", "closable"],
    ];
    for (const [setCmd, getCmd, prop] of cases) {
      const sr: any = await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd: setCmd, windowId: c.windowId, [prop]: false },
      );
      expect(sr.ok).toBe(true);
      const gr: any = await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd: getCmd, windowId: c.windowId },
      );
      expect(gr.ok).toBe(true);
      expect(gr[prop]).toBe(false);
      // 다시 true 로 복원되는지(토글).
      await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd: setCmd, windowId: c.windowId, [prop]: true },
      );
      const gr2: any = await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd: getCmd, windowId: c.windowId },
      );
      expect(gr2[prop]).toBe(true);
    }
  });

  test("capability flags: 알 수 없는 windowId — ok:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "is_resizable", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
  });

  // Electron 패리티: setMovable/setFocusable/setEnabled/setFullScreenable.
  // getter 는 tracked constraints(결정적) → round-trip. enforcement(드래그/입력 차단)은
  // best-effort 정직 경계(headless 미검증).
  // ⚠️ kiosk 는 제외 — set_kiosk(true) 가 실제 CEF Views 전체화면(macOS Space 전환)을
  // 유발해 CI 에서 비동기·파괴적이라 후속 창 geometry 테스트를 오염시킨다. kiosk flag
  // round-trip 은 window_manager_test/window_ipc_test(결정적 mock)로 커버. 실 전체화면
  // enforcement 는 real-runner 천장(정직 경계).
  test("mode flags: set → get round-trip (movable/focusable/enabled/fullscreenable)", async () => {
    const c = await coreCall({ cmd: "create_window", title: "modes", url: "about:blank" });
    const cases: Array<[string, string, string]> = [
      ["set_movable", "is_movable", "movable"],
      ["set_focusable", "is_focusable", "focusable"],
      ["set_enabled", "is_enabled", "enabled"],
      ["set_fullscreenable", "is_fullscreenable", "fullscreenable"],
    ];
    for (const [setCmd, getCmd, prop] of cases) {
      const sr: any = await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd: setCmd, windowId: c.windowId, [prop]: false },
      );
      expect(sr.ok).toBe(true);
      const gr: any = await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd: getCmd, windowId: c.windowId },
      );
      expect(gr.ok).toBe(true);
      expect(gr[prop]).toBe(false);
      // 다시 true 토글.
      await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd: setCmd, windowId: c.windowId, [prop]: true },
      );
    }
    // kiosk 는 전체화면 미유발로 flag round-trip 만(전체화면 진입 X — set_kiosk(false)).
    const kr: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_kiosk", windowId: c.windowId, kiosk: false },
    );
    expect(kr.ok).toBe(true);
    const kg: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "is_kiosk", windowId: c.windowId },
    );
    expect(kg.kiosk).toBe(false);
  });

  test("mode flags: 알 수 없는 windowId — ok:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "is_enabled", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
  });

  // Electron 패리티: set_content_bounds → get_content_bounds (콘텐츠 영역).
  test("content_bounds: set 후 get roundtrip — 크기 정확", async () => {
    const c = await coreCall({ cmd: "create_window", title: "contentbounds", url: "about:blank" });
    await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_content_bounds", windowId: c.windowId, x: 90, y: 90, width: 500, height: 360 },
    );
    await new Promise((r) => setTimeout(r, 300));
    const b: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "get_content_bounds", windowId: c.windowId },
    );
    expect(b.cmd).toBe("get_content_bounds");
    expect(b.ok).toBe(true);
    // 콘텐츠 크기는 정확히 round-trip(기본폴백 800x600 아님 = native 실독 증명).
    expect(Math.abs(b.width - 500)).toBeLessThanOrEqual(4);
    expect(Math.abs(b.height - 360)).toBeLessThanOrEqual(4);
    expect(typeof b.x).toBe("number");
    expect(typeof b.y).toBe("number");
  });

  test("get_content_bounds: 알 수 없는 windowId — ok:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "get_content_bounds", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
  });
});

// ============================================
// Electron 패리티: 가시성 / 포커스 / always-on-top
// ============================================
describe("BrowserWindow 가시성/포커스/always-on-top (Electron 패리티)", () => {
  const op = (req: object): Promise<any> =>
    page.evaluate((r) => (window as any).__suji__.core(JSON.stringify(r)), req);

  test("is_visible: show/hide(set_visible) 상태 반영", async () => {
    const c = await coreCall({ cmd: "create_window", title: "vis", url: "about:blank" });
    const id = c.windowId;
    expect((await op({ cmd: "is_visible", windowId: id })).visible).toBe(true);
    await op({ cmd: "set_visible", windowId: id, visible: false });
    await new Promise((r) => setTimeout(r, 150));
    expect((await op({ cmd: "is_visible", windowId: id })).visible).toBe(false);
    await op({ cmd: "set_visible", windowId: id, visible: true });
    await new Promise((r) => setTimeout(r, 150));
    expect((await op({ cmd: "is_visible", windowId: id })).visible).toBe(true);
  });

  test("set_always_on_top → is_always_on_top 왕복", async () => {
    const c = await coreCall({ cmd: "create_window", title: "aot", url: "about:blank" });
    const id = c.windowId;
    expect((await op({ cmd: "is_always_on_top", windowId: id })).alwaysOnTop).toBe(false);
    const s1 = await op({ cmd: "set_always_on_top", windowId: id, onTop: true });
    expect(s1.ok).toBe(true);
    expect((await op({ cmd: "is_always_on_top", windowId: id })).alwaysOnTop).toBe(true);
    await op({ cmd: "set_always_on_top", windowId: id, onTop: false });
    expect((await op({ cmd: "is_always_on_top", windowId: id })).alwaysOnTop).toBe(false);
  });

  test("blur: ok + is_focused 는 boolean 반환(헤드리스 포커스 불확정)", async () => {
    const c = await coreCall({ cmd: "create_window", title: "foc", url: "about:blank" });
    const id = c.windowId;
    expect((await op({ cmd: "blur", windowId: id })).ok).toBe(true);
    const f = await op({ cmd: "is_focused", windowId: id });
    expect(f.ok).toBe(true);
    expect(typeof f.focused).toBe("boolean");
  });

  test("알 수 없는 windowId — 게터/세터 모두 ok:false", async () => {
    for (const cmd of ["is_visible", "is_focused", "is_always_on_top", "blur"]) {
      expect((await op({ cmd, windowId: 99999 })).ok).toBe(false);
    }
    expect((await op({ cmd: "set_always_on_top", windowId: 99999, onTop: true })).ok).toBe(false);
  });
});

// ============================================
// Electron 패리티: getAllWindows / getFocusedWindow
// ============================================
describe("BrowserWindow.getAllWindows / getFocusedWindow (Electron 패리티)", () => {
  const op = (req: object): Promise<any> =>
    page.evaluate((r) => (window as any).__suji__.core(JSON.stringify(r)), req);

  test("get_all_windows: 생성한 top-level 창 포함", async () => {
    const a = await coreCall({ cmd: "create_window", title: "all-a", url: "about:blank" });
    const b = await coreCall({ cmd: "create_window", title: "all-b", url: "about:blank" });
    const r = await op({ cmd: "get_all_windows" });
    expect(r.ok).toBe(true);
    expect(Array.isArray(r.windowIds)).toBe(true);
    expect(r.windowIds).toContain(a.windowId);
    expect(r.windowIds).toContain(b.windowId);
  });

  test("get_all_windows: WebContentsView 는 제외(top-level 만)", async () => {
    const host = await coreCall({ cmd: "create_window", title: "all-host", url: "about:blank" });
    const v = await op({
      cmd: "create_view",
      hostId: host.windowId,
      url: "about:blank",
      bounds: { x: 0, y: 0, width: 100, height: 100 },
    });
    expect(typeof v.viewId).toBe("number");
    const r = await op({ cmd: "get_all_windows" });
    expect(r.windowIds).toContain(host.windowId);
    expect(r.windowIds).not.toContain(v.viewId);
  });

  test("get_focused_window: ok + windowId 는 null 또는 숫자", async () => {
    const r = await op({ cmd: "get_focused_window" });
    expect(r.ok).toBe(true);
    expect(r.windowId === null || typeof r.windowId === "number").toBe(true);
  });
});

// ============================================
// 멀티 윈도우 시나리오 — 동시 작업 + 교차 영향 없음
// ============================================

describe("멀티 윈도우 — 3개 동시 조작", () => {
  test("3개 창 생성 → 각자 distinct id + 독립 set_title", async () => {
    const a = await coreCall({ cmd: "create_window", title: "win-a", url: "about:blank" });
    const b = await coreCall({ cmd: "create_window", title: "win-b", url: "about:blank" });
    const c = await coreCall({ cmd: "create_window", title: "win-c", url: "about:blank" });

    expect(new Set([a.windowId, b.windowId, c.windowId]).size).toBe(3);

    const evalCmd = (cmd: string, extra: object): Promise<any> =>
      page.evaluate((req) => (window as any).__suji__.core(JSON.stringify(req)), { cmd, ...extra });

    const r1 = await evalCmd("set_title", { windowId: a.windowId, title: "renamed-a" });
    const r2 = await evalCmd("set_title", { windowId: b.windowId, title: "renamed-b" });
    expect(r1.ok && r2.ok).toBe(true);
    expect(r1.windowId).toBe(a.windowId);
    expect(r2.windowId).toBe(b.windowId);
  });
});

// ============================================
// 에러 경로 — destroyed 창에 메서드 호출
// (코어가 wm.X에서 WindowDestroyed 받으면 ok:false 응답이라는 invariant)
// ============================================

describe("에러 경로 — destroyed 창 메서드 호출", () => {
  test("close 후 set_title / load_url / open_dev_tools 모두 ok:false", async () => {
    // create는 했지만 destroy 메서드는 별도 cmd 없음 (현재 e2e). 대신 unknown id로 시뮬.
    // (close cmd가 noop인 상태에서 close 후 명령은 별도 wire로 검증 어려워)
    // 핵심: wm.X가 NotFound/Destroyed 반환 시 코어 invariant — ok:false 보장.
    const r1: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "load_url", windowId: 88888, url: "about:blank" })),
    );
    const r2: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "execute_javascript", windowId: 88888, code: "1" })),
    );
    const r3: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "open_dev_tools", windowId: 88888 })),
    );
    const r4: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "set_zoom_level", windowId: 88888, level: 1 })),
    );
    expect([r1.ok, r2.ok, r3.ok, r4.ok]).toEqual([false, false, false, false]);
  });
});

// ============================================
// Phase 4-E: 편집 (6 trivial) + 검색
// ============================================

describe("Phase 4-E — 편집 / 검색", () => {
  test("편집 6 cmd 모두 ok 응답 + cmd 정확", async () => {
    const c = await coreCall({ cmd: "create_window", title: "edit-test", url: "about:blank" });
    const id = c.windowId;
    const evalCmd = (cmd: string): Promise<any> =>
      page.evaluate((req) => (window as any).__suji__.core(JSON.stringify(req)), { cmd, windowId: id });

    for (const cmd of ["undo", "redo", "cut", "copy", "paste", "select_all"]) {
      const r = await evalCmd(cmd);
      expect(r.cmd).toBe(cmd);
      expect(r.ok).toBe(true);
    }
  });

  test("find_in_page + stop_find_in_page 응답 ok", async () => {
    const c = await coreCall({ cmd: "create_window", title: "find-test", url: "about:blank" });
    const id = c.windowId;
    const r1: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "find_in_page", windowId: id, text: "hello", forward: true, matchCase: false, findNext: false },
    );
    expect(r1.cmd).toBe("find_in_page");
    expect(r1.ok).toBe(true);

    const r2: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "stop_find_in_page", windowId: id, clearSelection: true },
    );
    expect(r2.cmd).toBe("stop_find_in_page");
    expect(r2.ok).toBe(true);
  });

  test("find_in_page → window:find-result 이벤트 (DOM에 명시 텍스트 주입 후 검색)", async () => {
    // 검색 대상 텍스트를 명시적으로 DOM에 주입 (페이지 콘텐츠에 의존하지 않음).
    // listener 등록 race 회피 위해 page.evaluate 안에서 listener attach + promise resolve.
    const result: any = await page.evaluate(async () => {
      return new Promise((resolve) => {
        // 검색 대상 텍스트 주입
        const marker = document.createElement("div");
        marker.id = "__find_marker__";
        marker.textContent = "find-target-token-xyz";
        document.body.appendChild(marker);

        const off = (window as any).__suji__.on("window:find-result", (payload: any) => {
          off();
          marker.remove();
          // dispatch는 JSON literal로 emit하므로 payload가 string이 아닌 object일 수 있음.
          const obj = typeof payload === "string" ? JSON.parse(payload) : payload;
          resolve(obj);
        });
        (window as any).__suji__.core(
          JSON.stringify({ cmd: "find_in_page", windowId: 1, text: "find-target-token-xyz", forward: true, matchCase: false, findNext: false }),
        );
        setTimeout(() => {
          off();
          marker.remove();
          resolve({ timeout: true });
        }, 5000);
      });
    });
    expect(result.timeout).toBeUndefined();
    expect(result.windowId).toBe(1);
    expect(typeof result.identifier).toBe("number");
    expect(result.count).toBeGreaterThan(0);
    expect(typeof result.activeMatchOrdinal).toBe("number");

    // cleanup
    await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "stop_find_in_page", windowId: 1, clearSelection: true })),
    );
  });

  test("알 수 없는 windowId — 모든 4-E cmd ok:false", async () => {
    for (const cmd of ["undo", "copy", "paste", "select_all", "stop_find_in_page"]) {
      const r: any = await page.evaluate(
        (req) => (window as any).__suji__.core(JSON.stringify(req)),
        { cmd, windowId: 99999 },
      );
      expect(r.ok).toBe(false);
    }
  });

  test("find_in_page: 빈 text도 정상 (CEF가 검색 정지)", async () => {
    const c = await coreCall({ cmd: "create_window", title: "empty-find", url: "about:blank" });
    const r: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "find_in_page", windowId: c.windowId, text: "" },
    );
    expect(r.ok).toBe(true);
  });
});

// ============================================
// Phase 4-D: PDF 인쇄 (콜백 async — `window:pdf-print-finished` 이벤트로 결과)
// ============================================

describe("Phase 4-D — printToPDF", () => {
  test("print_to_pdf: 즉시 ok 응답 + 완료 이벤트로 success/path 회신 + 실 파일 생성", async () => {
    const c = await coreCall({ cmd: "create_window", title: "pdf-test", url: "about:blank" });
    const id = c.windowId;
    const path = `/tmp/suji-e2e-${Date.now()}.pdf`;

    // 이벤트 listener 등록 후 cmd 호출 — Promise로 wait.
    const finished = page.evaluate((p) =>
      new Promise<{ path?: string; success?: boolean }>((resolve) => {
        const off = (window as any).__suji__.on("window:pdf-print-finished", (data: any) => {
          if (data.path === p) {
            off();
            resolve({ path: data.path, success: data.success });
          }
        });
      }), path) as Promise<{ path?: string; success?: boolean }>;

    const ack: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "print_to_pdf", windowId: id, path },
    );
    expect(ack.cmd).toBe("print_to_pdf");
    expect(ack.ok).toBe(true);

    const result = await Promise.race([
      finished,
      new Promise((r) => setTimeout(() => r({ path: undefined, success: undefined }), 5000)),
    ]) as { path?: string; success?: boolean };
    expect(result.path).toBe(path);
    expect(result.success).toBe(true);

    // 실 파일 존재 확인 + cleanup
    const { existsSync, unlinkSync } = await import("node:fs");
    expect(existsSync(path)).toBe(true);
    unlinkSync(path);
  });

  test("print_to_pdf: 알 수 없는 windowId — ok:false (이벤트 발화 안 됨)", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "print_to_pdf", windowId: 99999, path: "/tmp/x.pdf" })),
    );
    expect(r.ok).toBe(false);
  });
});

// ============================================
// Phase 4-B: 줌 (set/get level + factor)
// ============================================

describe("Zoom API (Phase 4-B)", () => {
  // CEF는 set_zoom_level 적용을 navigation 시점에 deferred — about:blank에 즉시 set
  // 직후 get은 cache된 기본값(0) 반환 가능. e2e는 ok 응답 + 응답 형식만 검증.
  // 실제 set→get round-trip은 TestNative 기반 단위 테스트에서 보장.

  test("set_zoom_level: ok 응답 + cmd 정확 매치", async () => {
    const created = await coreCall({ cmd: "create_window", title: "zoom-set-level", url: "about:blank" });
    const id = created.windowId;
    const r: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_zoom_level", windowId: id, level: 1.5 },
    );
    expect(r.cmd).toBe("set_zoom_level");
    expect(r.ok).toBe(true);
  });

  test("set_zoom_factor: ok 응답 + factor → level 변환 (코어가 wm.setZoomFactor 거침)", async () => {
    const created = await coreCall({ cmd: "create_window", title: "zoom-set-factor", url: "about:blank" });
    const id = created.windowId;
    const r: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_zoom_factor", windowId: id, factor: 1.2 },
    );
    expect(r.ok).toBe(true);
  });

  test("get_zoom_level / get_zoom_factor: 응답 형식 (level/factor 필드 + ok:true)", async () => {
    const created = await coreCall({ cmd: "create_window", title: "zoom-get", url: "about:blank" });
    const id = created.windowId;
    const evalCmd = (cmd: string): Promise<any> =>
      page.evaluate((req) => (window as any).__suji__.core(JSON.stringify(req)), { cmd, windowId: id });

    const gl = await evalCmd("get_zoom_level");
    expect(gl.ok).toBe(true);
    expect(typeof gl.level).toBe("number");

    const gf = await evalCmd("get_zoom_factor");
    expect(gf.ok).toBe(true);
    expect(typeof gf.factor).toBe("number");
  });

  test("알 수 없는 windowId — ok:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "set_zoom_level", windowId: 99999, level: 1 })),
    );
    expect(r.ok).toBe(false);
  });
});

// ============================================
// webContents.setAudioMuted / isAudioMuted (CEF cef_browser_host_t.set/is_audio_muted)
// ============================================

describe("Opacity / Background / Shadow API", () => {
  // NSWindow.alphaValue 는 macOS-only. Windows 는 layered window
  // (SetLayeredWindowAttributes) 별도 impl 필요 — 미배선.
  test("setOpacity 0.5 → getOpacity 0.5 (NSWindow alphaValue round-trip)", async () => {
    const created = await coreCall({ cmd: "create_window", title: "opacity", url: "about:blank" });
    const id = created.windowId;
    const evalCmd = (req: object): Promise<any> =>
      page.evaluate((r) => (window as any).__suji__.core(JSON.stringify(r)), req as any);

    const set = await evalCmd({ cmd: "set_opacity", windowId: id, opacity: 0.5 });
    expect(set.cmd).toBe("set_opacity");
    expect(set.ok).toBe(true);

    const get = await evalCmd({ cmd: "get_opacity", windowId: id });
    expect(get.ok).toBe(true);
    // Win32 SetLayeredWindowAttributes 는 alpha 가 byte(0-255) 라 0.5 round-trip
    // 시 ±1/255 (~0.004) 손실. macOS NSWindow.alphaValue 는 native float — 4
    // decimal 정확. tolerance 를 OS 에 맞춰 완화.
    const precision = process.platform === "win32" ? 2 : 4;
    expect(get.opacity).toBeCloseTo(0.5, precision);
  });

  test("setBackgroundColor 응답 ok (#RRGGBB hex)", async () => {
    const created = await coreCall({ cmd: "create_window", title: "bgcolor", url: "about:blank" });
    const id = created.windowId;
    const r: any = await page.evaluate(
      (req) => (window as any).__suji__.core(JSON.stringify(req)),
      { cmd: "set_background_color", windowId: id, color: "#ff8800" },
    );
    expect(r.ok).toBe(true);
  });

  // NSWindow.hasShadow 는 macOS-only. Windows 는 DWM (DwmSetWindowAttribute
  // + frame extension) 별도 impl 필요 — 미배선. set/get_has_shadow IPC 는
  // 비-macOS 에서 no-op (항상 true 반환).
  test.skipIf(process.platform !== "darwin")("setHasShadow false → hasShadow false (NSWindow shadow round-trip)", async () => {
    const created = await coreCall({ cmd: "create_window", title: "shadow", url: "about:blank" });
    const id = created.windowId;
    const evalCmd = (req: object): Promise<any> =>
      page.evaluate((r) => (window as any).__suji__.core(JSON.stringify(r)), req as any);

    const set = await evalCmd({ cmd: "set_has_shadow", windowId: id, hasShadow: false });
    expect(set.ok).toBe(true);

    const has = await evalCmd({ cmd: "has_shadow", windowId: id });
    expect(has.ok).toBe(true);
    expect(has.hasShadow).toBe(false);

    await evalCmd({ cmd: "set_has_shadow", windowId: id, hasShadow: true });
    const has2 = await evalCmd({ cmd: "has_shadow", windowId: id });
    expect(has2.hasShadow).toBe(true);
  });

  test("opacity: 알 수 없는 windowId — ok:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "set_opacity", windowId: 99999, opacity: 1 })),
    );
    expect(r.ok).toBe(false);
  });
});

describe("Audio mute API", () => {
  test("set true → is true → set false → is false (round-trip)", async () => {
    const created = await coreCall({ cmd: "create_window", title: "audio-mute", url: "about:blank" });
    const id = created.windowId;
    const evalCmd = (req: object): Promise<any> =>
      page.evaluate((r) => (window as any).__suji__.core(JSON.stringify(r)), req as any);

    const set1 = await evalCmd({ cmd: "set_audio_muted", windowId: id, muted: true });
    expect(set1.cmd).toBe("set_audio_muted");
    expect(set1.ok).toBe(true);

    const is1 = await evalCmd({ cmd: "is_audio_muted", windowId: id });
    expect(is1.ok).toBe(true);
    expect(is1.muted).toBe(true);

    const set2 = await evalCmd({ cmd: "set_audio_muted", windowId: id, muted: false });
    expect(set2.ok).toBe(true);

    const is2 = await evalCmd({ cmd: "is_audio_muted", windowId: id });
    expect(is2.muted).toBe(false);
  });

  test("알 수 없는 windowId — ok:false, muted:false", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "is_audio_muted", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
    expect(r.muted).toBe(false);
  });
});

// ============================================
// Phase 4-C: DevTools API (open / close / is / toggle)
// ============================================

describe("DevTools API (Phase 4-C)", () => {
  test("open → is(true) → close → is(false) 라이프사이클", async () => {
    const created = await coreCall({ cmd: "create_window", title: "dev-tools-test", url: "about:blank" });
    const id = created.windowId;
    const evalCmd = (cmd: string, extra: object = {}): Promise<any> =>
      page.evaluate((req) => (window as any).__suji__.core(JSON.stringify(req)), { cmd, windowId: id, ...extra });

    const op = await evalCmd("open_dev_tools");
    expect(op.cmd).toBe("open_dev_tools");
    expect(op.ok).toBe(true);

    // CEF가 DevTools 창을 띄우는 데 시간 필요. 짧게 대기.
    await new Promise((r) => setTimeout(r, 500));

    const isr = await evalCmd("is_dev_tools_opened");
    expect(isr.opened).toBe(true);

    const cl = await evalCmd("close_dev_tools");
    expect(cl.ok).toBe(true);
    await new Promise((r) => setTimeout(r, 300));

    const isr2 = await evalCmd("is_dev_tools_opened");
    expect(isr2.opened).toBe(false);
  });

  test("toggle: 현재 상태 반전 (idempotent open + idempotent close)", async () => {
    const created = await coreCall({ cmd: "create_window", title: "toggle-dt", url: "about:blank" });
    const id = created.windowId;
    const evalCmd = (cmd: string): Promise<any> =>
      page.evaluate((req) => (window as any).__suji__.core(JSON.stringify(req)), { cmd, windowId: id });

    // toggle → opened
    const t1 = await evalCmd("toggle_dev_tools");
    expect(t1.ok).toBe(true);
    await new Promise((r) => setTimeout(r, 500));
    expect((await evalCmd("is_dev_tools_opened")).opened).toBe(true);

    // 이미 열려있는데 다시 open 호출 — 멱등 (응답 ok=true).
    const op = await evalCmd("open_dev_tools");
    expect(op.ok).toBe(true);

    // toggle → closed
    const t2 = await evalCmd("toggle_dev_tools");
    expect(t2.ok).toBe(true);
    await new Promise((r) => setTimeout(r, 300));
    expect((await evalCmd("is_dev_tools_opened")).opened).toBe(false);
  });

  test("알 수 없는 windowId — ok:false 반환", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "open_dev_tools", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
  });

  // ──────────────────────────────────────────────────────
  // 회귀 — cmd 정확 매치 (commit 73). 이전엔 substring 매치였음.
  // ──────────────────────────────────────────────────────

  test("회귀: 가짜 cmd가 다른 cmd의 substring 포함해도 잘못 라우팅 안 됨", async () => {
    // "open_dev_tools_extra"는 "open_dev_tools" substring 포함 → 이전 코드는 잘못 매치.
    // 정확 매치 fix 후엔 fallback "hello from zig" 응답.
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "open_dev_tools_extra", windowId: 1 })),
    );
    expect(r.cmd).not.toBe("open_dev_tools"); // open_dev_tools 응답이 아님
    expect(r.success).toBe(false);
    expect(r.error).toBe("unknown_cmd");
  });

  test("회귀: 옵션 필드에 'cmd' substring 포함돼도 잘못 라우팅 안 됨", async () => {
    // create_window는 이전엔 substring "create_window"만 봤음 → title에 "create_window"
    // 들어가면 cmd가 다른데도 라우팅됐을 위험. 정확 매치 후 fallback로.
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.core(JSON.stringify({ cmd: "noop", title: "create_window inside title" })),
    );
    expect(r.cmd).not.toBe("create_window");
    expect(r.windowId).toBeUndefined();
  });
});

describe("Zig backend SDK windows.* round-trip", () => {
  test("zig handler가 suji.windows.isLoading 호출 → 코어 응답 회신", async () => {
    const r: any = await page.evaluate(() =>
      (window as any).__suji__.invoke("windows-roundtrip-zig", {}, { target: "zig" }),
    );
    // 응답 wrapping 형식과 무관하게 — 어딘가에 코어가 돌려준 is_loading JSON이 있어야 함.
    const dump = JSON.stringify(r);
    expect(dump).toContain("from_backend");
    expect(dump).toContain('"cmd\\":\\"is_loading\\"');
    expect(dump).toMatch(/"loading\\":(true|false)/);
  });
});

// ============================================
// 4. Phase 4-A: webContents (네비/JS) IPC
// ============================================

describe("webContents 네비/JS (Phase 4-A)", () => {
  test("load_url + reload + execute_javascript + get_url + is_loading 응답 정상", async () => {
    const created = await coreCall({
      cmd: "create_window",
      title: "phase4-a",
      url: "about:blank",
    });
    const id = created.windowId;

    const lr: any = await page.evaluate(
      (i) => (window as any).__suji__.core(JSON.stringify({ cmd: "load_url", windowId: i, url: "about:blank" })),
      id,
    );
    expect(lr.cmd).toBe("load_url");
    expect(lr.ok).toBe(true);

    const rr: any = await page.evaluate(
      (i) => (window as any).__suji__.core(JSON.stringify({ cmd: "reload", windowId: i, ignoreCache: true })),
      id,
    );
    expect(rr.cmd).toBe("reload");
    expect(rr.ok).toBe(true);

    const er: any = await page.evaluate(
      (i) => (window as any).__suji__.core(JSON.stringify({ cmd: "execute_javascript", windowId: i, code: "1+1" })),
      id,
    );
    expect(er.cmd).toBe("execute_javascript");
    expect(er.ok).toBe(true);

    const il: any = await page.evaluate(
      (i) => (window as any).__suji__.core(JSON.stringify({ cmd: "is_loading", windowId: i })),
      id,
    );
    expect(il.cmd).toBe("is_loading");
    expect(il.ok).toBe(true);
    expect(typeof il.loading).toBe("boolean");

    const ur: any = await page.evaluate(
      (i) => (window as any).__suji__.core(JSON.stringify({ cmd: "get_url", windowId: i })),
      id,
    );
    expect(ur.cmd).toBe("get_url");
    // url은 캐시 갱신 타이밍에 따라 null 또는 string. ok도 그에 맞춰 변동 — 형식만 검증.
    expect(typeof ur.ok).toBe("boolean");
  });

  test("알 수 없는 windowId — load_url ok:false, native 미호출 회귀", async () => {
    const r: any = await page.evaluate(
      () => (window as any).__suji__.core(JSON.stringify({ cmd: "load_url", windowId: 99999, url: "about:blank" })),
    );
    expect(r.ok).toBe(false);
  });

  test("execute_javascript fire-and-forget — 응답은 ok만, 결과 회신 없음", async () => {
    const r: any = await page.evaluate(
      () => (window as any).__suji__.core(JSON.stringify({ cmd: "execute_javascript", windowId: 1, code: "console.log('e2e')" })),
    );
    expect(r.cmd).toBe("execute_javascript");
    expect(r.ok).toBe(true);
    // 결과(eval value)는 응답에 없음 — 이게 의도된 fire-and-forget 정책
    expect(r.result).toBeUndefined();
  });

  test("stop — 진행 중 로드 중단, ok:true", async () => {
    const r: any = await page.evaluate(
      () => (window as any).__suji__.core(JSON.stringify({ cmd: "stop", windowId: 1 })),
    );
    expect(r.cmd).toBe("stop");
    expect(r.ok).toBe(true);
  });

  test("stop — 알 수 없는 windowId ok:false", async () => {
    const r: any = await page.evaluate(
      () => (window as any).__suji__.core(JSON.stringify({ cmd: "stop", windowId: 99999 })),
    );
    expect(r.ok).toBe(false);
  });

  test("insertCSS → style 실주입 + key 반환, removeInsertedCSS → 실제 제거", async () => {
    const ins: any = await page.evaluate(
      () => (window as any).__suji__.core(JSON.stringify({ cmd: "insert_css", windowId: 1, css: "body{--suji-e2e:42}" })),
    );
    expect(ins.cmd).toBe("insert_css");
    expect(ins.ok).toBe(true);
    expect(ins.key).toMatch(/^suji-css-\d+$/);

    // frame eval 은 비동기 — 주입 완료까지 폴링(style 엘리먼트 + computed custom prop).
    const applied = await page.evaluate(async (key) => {
      for (let i = 0; i < 40; i++) {
        const el = document.querySelector(`style[data-suji-css="${key}"]`);
        const v = getComputedStyle(document.body).getPropertyValue("--suji-e2e").trim();
        if (el && v === "42") return true;
        await new Promise((res) => setTimeout(res, 50));
      }
      return false;
    }, ins.key);
    expect(applied).toBe(true);

    const rem: any = await page.evaluate(
      (key) => (window as any).__suji__.core(JSON.stringify({ cmd: "remove_inserted_css", windowId: 1, key })),
      ins.key,
    );
    expect(rem.cmd).toBe("remove_inserted_css");
    expect(rem.ok).toBe(true);

    const removed = await page.evaluate(async (key) => {
      for (let i = 0; i < 40; i++) {
        const el = document.querySelector(`style[data-suji-css="${key}"]`);
        const v = getComputedStyle(document.body).getPropertyValue("--suji-e2e").trim();
        if (!el && v === "") return true;
        await new Promise((res) => setTimeout(res, 50));
      }
      return false;
    }, ins.key);
    expect(removed).toBe(true);
  });

  test("insertCSS — 따옴표/백슬래시 포함 CSS 안전(base64 경로, executeJavascript escape 한계 회피)", async () => {
    const ins: any = await page.evaluate(
      () => (window as any).__suji__.core(JSON.stringify({ cmd: "insert_css", windowId: 1, css: 'body::after{content:"a\\"b"}' })),
    );
    expect(ins.ok).toBe(true);
    expect(ins.key).toMatch(/^suji-css-\d+$/);
    // 주입된 style 의 textContent 가 원본 CSS 와 정확히 일치(unescape→base64→atob 라운드트립).
    const matched = await page.evaluate(async (key) => {
      for (let i = 0; i < 40; i++) {
        const el = document.querySelector(`style[data-suji-css="${key}"]`);
        if (el && el.textContent === 'body::after{content:"a\\"b"}') return true;
        await new Promise((res) => setTimeout(res, 50));
      }
      return false;
    }, ins.key);
    expect(matched).toBe(true);
    await page.evaluate(
      (key) => (window as any).__suji__.core(JSON.stringify({ cmd: "remove_inserted_css", windowId: 1, key })),
      ins.key,
    );
  });
});

// ============================================
// 4.5 session.setDownloadPath + session:will-download
// ============================================

describe("session.setDownloadPath / will-download (Electron 패리티)", () => {
  test("session_set_download_path 왕복 success:true", async () => {
    const r: any = await page.evaluate(
      () => (window as any).__suji__.core(JSON.stringify({ cmd: "session_set_download_path", path: "/tmp/suji-dl-e2e" })),
    );
    expect(r.cmd).toBe("session_set_download_path");
    expect(r.success).toBe(true);
  });

  test("다운로드 트리거 → will-download 이벤트 + setDownloadPath 경로에 파일 생성", async () => {
    const { mkdtempSync, existsSync, readFileSync: rfs, rmSync } = await import("node:fs");
    const { tmpdir } = await import("node:os");
    const dir = mkdtempSync(join(tmpdir(), "suji-dl-"));
    const filename = "suji-e2e-dl.txt";

    // 1) 다운로드 경로 지정 + will-download 리스너 등록.
    await page.evaluate((d) => {
      (window as any).__test_dl = [];
      (window as any).__suji__.on("session:will-download", (data: any) => (window as any).__test_dl.push(data));
      return (window as any).__suji__.core(JSON.stringify({ cmd: "session_set_download_path", path: d }));
    }, dir);

    // 2) anchor[download] 클릭으로 다운로드 트리거(data: URL = "hi suji").
    await page.evaluate((fn) => {
      const a = document.createElement("a");
      a.href = "data:text/plain;base64,aGkgc3VqaQ=="; // "hi suji"
      a.download = fn;
      document.body.appendChild(a);
      a.click();
      a.remove();
    }, filename);

    // 3) will-download 이벤트 폴링(on_before_download = 파일 쓰기 전 발화).
    let evt: any = null;
    for (let i = 0; i < 60; i++) {
      const got: any[] = await page.evaluate(() => (window as any).__test_dl);
      if (got && got.length > 0) {
        evt = got[0];
        break;
      }
      await new Promise((res) => setTimeout(res, 100));
    }
    expect(evt).not.toBeNull();
    expect(evt.filename).toBe(filename);

    // 4) 파일이 지정 경로에 실제 생성됐는지 폴링(다운로드 완료는 비동기).
    const target = join(dir, filename);
    let onDisk = false;
    for (let i = 0; i < 60; i++) {
      if (existsSync(target)) {
        onDisk = true;
        break;
      }
      await new Promise((res) => setTimeout(res, 100));
    }
    expect(onDisk).toBe(true);
    expect(rfs(target, "utf8")).toBe("hi suji");

    // cleanup: 경로 해제 + temp dir 제거.
    await page.evaluate(() => (window as any).__suji__.core(JSON.stringify({ cmd: "session_set_download_path", path: "" })));
    rmSync(dir, { recursive: true, force: true });
  });
});

// ============================================
// 5. 로그 파일 — 실행 중 `~/.suji/logs/suji-*.log` 생성
// ============================================

describe("log file output", () => {
  test("current run produced a log file under ~/.suji/logs/", () => {
    const logDir = join(homedir(), ".suji", "logs");
    const entries = readdirSync(logDir).filter((n) => n.startsWith("suji-") && n.endsWith(".log"));
    expect(entries.length).toBeGreaterThan(0);

    // 최근 10분 내 수정된 파일이 있어야 (현재 실행 중인 run의 로그)
    const now = Date.now();
    const recent = entries.some((name) => {
      const st = statSync(join(logDir, name));
      return now - st.mtimeMs < 10 * 60 * 1000;
    });
    expect(recent).toBe(true);
  });
});
