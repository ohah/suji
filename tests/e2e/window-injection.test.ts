/**
 * Phase 2.5 Step 1 — `__window` wire-level 자동 주입 E2E.
 *
 * 프론트엔드에서 `__suji__.invoke`가 호출된 창의 WM id가 백엔드 request JSON에
 * 자동으로 `__window` 필드로 주입되는지를 검증.
 *
 * ## 전제
 *
 * 다음 두 가지가 이미 세팅되어 있어야 함 (편의 스크립트: `tests/e2e/run-window-injection.sh`):
 *
 *   (1) `cd examples/multi-backend && SUJI_TRACE_IPC=1 <suji> dev | tee <LOG_PATH>`
 *       — `SUJI_TRACE_IPC=1` 환경변수가 켜져야 zig 백엔드의 ping 핸들러가
 *         `[zig/ping] raw={...}` 형태로 stderr에 출력함. `tee`로 stderr가 <LOG_PATH>에 미러링.
 *
 *   (2) `SUJI_LOG=<LOG_PATH> bun test tests/e2e/window-injection.test.ts`
 *       — 기본 경로: `/tmp/suji-e2e.log`
 *
 * ## 검증 범위
 *
 *   - 창 1개(id=1)에서 `suji.invoke('ping', ..., { target: 'zig' })` → wire JSON에 `"__window":1` 자동 주입
 *   - `create_window` IPC로 창 2개, 3개로 확장 → CEF가 실제 새 browser 생성 (`after_created` 로그)
 *
 * 창 2/3에서 직접 ping을 보내는 것은 puppeteer가 CEF Alloy의 신규 browser target에 attach가
 * 불안정해서 제외. 주입 로직 자체는 `tests/window_ipc_test.zig`의 `injectWindowField` 단위
 * 테스트로 이미 보장됨 (엣지 케이스 7종).
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { readFileSync } from "node:fs";

const LOG_PATH = process.env.SUJI_LOG ?? "/tmp/suji-e2e.log";

let browser: Browser;
let page1: Page;

const invokePing = (p: Page) =>
  p.evaluate(() => (window as any).__suji__.invoke("ping", {}, { target: "zig" }));

const createWindow = (p: Page, title: string) =>
  p.evaluate(
    (t) =>
      (window as any).__suji__.core(
        JSON.stringify({ cmd: "create_window", title: t, url: "http://localhost:5173" }),
      ),
    title,
  ) as Promise<{ windowId: number }>;

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

describe("Phase 2.5 — __window wire injection", () => {
  test("main window invoke → __window:1 자동 주입", async () => {
    const before = logLength(LOG_PATH);
    const resp = await invokePing(page1);
    expect(resp).toBeDefined();

    await new Promise((r) => setTimeout(r, 300));
    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(/\[zig\/ping\] raw=\{"cmd":"ping","__window":1\}/);
  });

  test("create_window으로 창 2개 확장 — CEF가 실제 browser 생성", async () => {
    const before = logLength(LOG_PATH);
    const created = await createWindow(page1, "Window-2");
    expect(created.windowId).toBeGreaterThanOrEqual(2);

    await new Promise((r) => setTimeout(r, 1000));
    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(/CEF browser after_created: id=\d+/);
    expect(tail).toMatch(/V8 context created/);
  }, 15000);

  test("create_window으로 창 3개 확장 — 새 browser + V8 context 생성", async () => {
    const before = logLength(LOG_PATH);
    const created = await createWindow(page1, "Window-3");
    expect(created.windowId).toBeGreaterThanOrEqual(3);

    await new Promise((r) => setTimeout(r, 1000));
    const tail = readLogTail(LOG_PATH, before);
    expect(tail).toMatch(/CEF browser after_created: id=\d+/);
    expect(tail).toMatch(/V8 context created/);
  }, 15000);
});
