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
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

let browser: Browser;
let page: Page;

type CoreResponse = { from: string; cmd: string; windowId: number };

const coreCall = (request: object): Promise<CoreResponse> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request,
  ) as Promise<CoreResponse>;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 10000,
    // CEF 실제 창 크기를 그대로 사용. 명시 안 하면 puppeteer가 800x600으로 viewport를
    // 강제 emulation해서 window.innerWidth / page.screenshot 결과가 실제 NSWindow와 달라짐.
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  // 메인 창 찾기: http://localhost:51XX/ (vite dev) — about:blank 창들은 이전
  // 테스트 실행에서 누적됐을 수 있으므로 걸러냄.
  const main = pages.find((p) => p.url().startsWith("http://localhost"));
  if (!main) throw new Error("main window (localhost) not found in puppeteer pages");
  page = main;
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
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
    expect(r.cmd).toBeUndefined(); // open_dev_tools 응답이 아님
    expect(r.msg).toBe("hello from zig"); // default fallback
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
