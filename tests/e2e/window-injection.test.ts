/**
 * Phase 2.5 Step 1 — `__window` wire-level 자동 주입 E2E.
 *
 * 프론트엔드에서 `__suji__.invoke`가 호출된 창의 WM id가 백엔드 request JSON에
 * 자동으로 `__window` 필드로 주입되는지를 검증 — 1/2/3개 창 모두.
 *
 * ## 전제
 *
 * 편의 스크립트: `bash tests/e2e/run-window-injection.sh`가 아래를 자동 세팅:
 *
 *   (1) `cd examples/multi-backend && SUJI_TRACE_IPC=1 <suji> dev | tee <LOG_PATH>`
 *       — `SUJI_TRACE_IPC=1` 환경변수가 켜져야 zig 백엔드의 ping 핸들러가
 *         `[zig/ping] raw={...}` 형태로 stderr에 출력함. `tee`로 stderr를 <LOG_PATH>에 미러링.
 *   (2) `SUJI_LOG=<LOG_PATH> bun test tests/e2e/window-injection.test.ts`
 *       — 기본 경로: `/tmp/suji-e2e.log`.
 *
 * ## 구현 노트 — puppeteer + CEF Alloy 신규 browser attach
 *
 * `puppeteer.connect({ browserURL })` 모드는 CDP 서버에서 신규 target을 discover만 하고
 * Page 객체 자동 attach는 하지 않음. `target.page()`는 null을 계속 반환. 대신
 * `target.createCDPSession()`으로 raw CDP 세션을 만들어 `Runtime.evaluate`로 JS를
 * 실행하면 신규 창에서도 호출 가능. main 창은 beforeAll에서 `browser.pages()[0]`로
 * 이미 attached 상태이므로 Page API 그대로 사용.
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, {
  type Browser,
  type Page,
  type CDPSession,
  type Target,
} from "puppeteer-core";
import { readFileSync } from "node:fs";

const LOG_PATH = process.env.SUJI_LOG ?? "/tmp/suji-e2e.log";

let browser: Browser;
let page1: Page;

const PING_EXPR = `window.__suji__.invoke("ping", {}, { target: "zig" })`;

const pingViaPage = (p: Page) =>
  p.evaluate(() => (window as any).__suji__.invoke("ping", {}, { target: "zig" }));

const pingViaCDP = async (session: CDPSession) =>
  (
    await session.send("Runtime.evaluate", {
      expression: PING_EXPR,
      awaitPromise: true,
      returnByValue: true,
    })
  ).result.value;

const createWindow = (p: Page, title: string) =>
  p.evaluate(
    (t) =>
      (window as any).__suji__.core(
        JSON.stringify({ cmd: "create_window", title: t, url: "http://localhost:5173" }),
      ),
    title,
  ) as Promise<{ windowId: number }>;

async function waitForNewPageTarget(excluded: Set<Target>, timeoutMs = 5000): Promise<Target> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const cand = browser.targets().find((t) => t.type() === "page" && !excluded.has(t));
    if (cand) return cand;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("new page target not discovered in time");
}

function readLogTail(path: string, startOffset: number): string {
  try {
    return readFileSync(path, "utf-8").slice(startOffset);
  } catch {
    return "";
  }
}

function logLength(path: string): number {
  try {
    return readFileSync(path, "utf-8").length;
  } catch {
    return 0;
  }
}

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 10000,
  });
  const pages = await browser.pages();
  const main = pages.find((p) => p.url().startsWith("http://localhost"));
  if (!main) {
    throw new Error(
      "main window (localhost) not found — is `suji dev` running with DevTools on :9222?",
    );
  }
  page1 = main;
  page1.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("Phase 2.5 — __window wire injection (1~3 windows)", () => {
  test("1개 창: 메인(id=1) ping → __window:1 주입", async () => {
    const before = logLength(LOG_PATH);
    const resp = await pingViaPage(page1);
    expect(resp).toBeDefined();

    await new Promise((r) => setTimeout(r, 300));
    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(/\[zig\/ping\] window\.id=1 raw=\{"cmd":"ping","__window":1\}/);
  });

  test("2개 창: 각 창에서 ping → 서로 다른 __window id 주입", async () => {
    const excluded = new Set<Target>([page1.target()]);
    const created = await createWindow(page1, "Window-2");
    expect(created.windowId).toBeGreaterThanOrEqual(2);

    const target2 = await waitForNewPageTarget(excluded);
    const cdp2 = await target2.createCDPSession();

    const before = logLength(LOG_PATH);
    await pingViaPage(page1);
    await pingViaCDP(cdp2);
    await new Promise((r) => setTimeout(r, 500));

    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(/\[zig\/ping\] window\.id=1 raw=\{"cmd":"ping","__window":1\}/);
    expect(tail).toMatch(
      new RegExp(
        `\\[zig/ping\\] window\\.id=${created.windowId} raw=\\{"cmd":"ping","__window":${created.windowId}\\}`,
      ),
    );
    expect(created.windowId).not.toBe(1);

    await cdp2.detach();
  }, 15000);

  test("2-arity 핸들러가 InvokeEvent.window.id를 받음 (response에 포함)", async () => {
    // zig 백엔드 ping은 2-arity로 바뀌었고 응답에 window_id 포함.
    const resp = (await pingViaPage(page1)) as { result: { window_id: number } };
    expect(resp.result.window_id).toBe(1);
  });

  test("3개 창: 각 창에서 ping → distinct __window 세 값", async () => {
    const page1Target = page1.target();
    const excludedBefore = new Set<Target>(browser.targets().filter((t) => t.type() === "page"));

    const created = await createWindow(page1, "Window-3");
    expect(created.windowId).toBeGreaterThanOrEqual(3);

    const target3 = await waitForNewPageTarget(excludedBefore);
    const cdp3 = await target3.createCDPSession();

    // page2: page1Target이 아니고 target3도 아닌 page 중 하나
    const page2Target = browser
      .targets()
      .find((t) => t.type() === "page" && t !== page1Target && t !== target3)!;
    expect(page2Target).toBeDefined();
    const cdp2 = await page2Target.createCDPSession();

    const before = logLength(LOG_PATH);
    await pingViaPage(page1);
    await pingViaCDP(cdp2);
    await pingViaCDP(cdp3);
    await new Promise((r) => setTimeout(r, 500));

    const tail = readLogTail(LOG_PATH, before);
    const ids = [...tail.matchAll(/"__window":(\d+)/g)].map((m) => Number(m[1]));
    const unique = new Set(ids);
    expect(unique.size).toBeGreaterThanOrEqual(3);
    expect(unique.has(1)).toBe(true);
    expect(unique.has(created.windowId)).toBe(true);

    await cdp2.detach();
    await cdp3.detach();
  }, 15000);
});
