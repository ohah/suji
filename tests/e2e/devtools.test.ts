/**
 * Phase 4-C DevTools E2E — `windows.{openDevTools, closeDevTools, isDevToolsOpened, toggleDevTools}`.
 *
 * 회귀 테스트는 정적 ObjC selector + 매핑 패턴만 검증. 이 E2E는 IPC 라운드트립 + 상태 토글:
 *   - openDevTools → isDevToolsOpened true
 *   - closeDevTools → isDevToolsOpened false
 *   - toggleDevTools 반복 → 상태 alternates
 *   - 잘못된 windowId graceful
 *
 * 실행: tests/e2e/run-devtools.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;
const windowId = 1;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

const wait = (ms: number) => new Promise(r => setTimeout(r, ms));

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  page = pages[0];
  page.setDefaultTimeout(15000);
});

afterAll(async () => {
  // ensure DevTools closed for clean shutdown
  try { await core({ cmd: "close_dev_tools", windowId }); } catch {}
  await browser?.disconnect();
});

describe("openDevTools / isDevToolsOpened / closeDevTools", () => {
  test("초기 상태: closed", async () => {
    await core({ cmd: "close_dev_tools", windowId });
    await wait(500);
    const r = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r.opened).toBe(false);
  });

  test("openDevTools → opened: true", async () => {
    await core({ cmd: "open_dev_tools", windowId });
    await wait(800); // CEF DevTools 비동기 — 잠깐 대기
    const r = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r.opened).toBe(true);
  });

  test("closeDevTools → opened: false", async () => {
    await core({ cmd: "close_dev_tools", windowId });
    await wait(500);
    const r = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r.opened).toBe(false);
  });
});

describe("toggleDevTools — 상태 alternation", () => {
  test("초기 closed → toggle → opened", async () => {
    await core({ cmd: "close_dev_tools", windowId });
    await wait(500);

    await core({ cmd: "toggle_dev_tools", windowId });
    await wait(800);
    const r1 = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r1.opened).toBe(true);

    await core({ cmd: "toggle_dev_tools", windowId });
    await wait(500);
    const r2 = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r2.opened).toBe(false);
  });

  test("toggle 3번 → opened (홀수)", async () => {
    await core({ cmd: "close_dev_tools", windowId });
    await wait(500);

    for (let i = 0; i < 3; i++) {
      await core({ cmd: "toggle_dev_tools", windowId });
      await wait(500);
    }
    const r = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r.opened).toBe(true);

    // cleanup
    await core({ cmd: "close_dev_tools", windowId });
  });
});

describe("openDevTools 멱등성", () => {
  test("openDevTools 두 번 호출 — 두 번째는 no-op (no crash)", async () => {
    await core({ cmd: "close_dev_tools", windowId });
    await wait(500);

    await core({ cmd: "open_dev_tools", windowId });
    await wait(800);
    await core({ cmd: "open_dev_tools", windowId }); // 두 번째 호출
    await wait(300);

    const r = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r.opened).toBe(true);

    await core({ cmd: "close_dev_tools", windowId });
  });

  test("closeDevTools 두 번 호출 — 두 번째는 no-op", async () => {
    await core({ cmd: "close_dev_tools", windowId });
    await wait(500);
    await core({ cmd: "close_dev_tools", windowId });
    await wait(300);
    const r = await core<{ opened: boolean }>({ cmd: "is_dev_tools_opened", windowId });
    expect(r.opened).toBe(false);
  });
});

describe("error / 잘못된 windowId", () => {
  test("openDevTools 잘못된 windowId — graceful (응답은 옴)", async () => {
    const r = await core<any>({ cmd: "open_dev_tools", windowId: 99999 });
    expect(r).toBeDefined();
  });

  test("isDevToolsOpened 잘못된 windowId — opened: false 또는 default", async () => {
    const r = await core<{ opened?: boolean }>({ cmd: "is_dev_tools_opened", windowId: 99999 });
    expect(r).toBeDefined();
  });
});
