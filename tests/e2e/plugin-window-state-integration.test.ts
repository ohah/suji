/**
 * 공식 window-state 플러그인 통합 e2e (실 CEF 창 라운드트립).
 *
 * 검증 범위:
 *   1. renderer 가 __suji__.invoke('window-state:save') → 플러그인이 **실 창**의
 *      getBounds/isMaximized 를 코어 window API(getWindowApi)로 읽어 파일에 영속
 *   2. 'window-state:get' 으로 저장값을 되읽어 라이브 창 bounds 와 일치(width/height>0)
 *   3. 'window-state:restore' 가 저장값을 창에 적용(restored:true)
 *   4. 'window-state:clear' 후 get → null, restore → restored:false
 *
 * Wrapper wire shape 은 `bun test plugins/window-state/{js,node}/src` 가 별도 검증.
 * 이 파일은 REAL plugin DLL ↔ 코어 window API ↔ renderer 통합만 검사
 * (unit test 는 window API 가 없어 file-path 핸들러 + graceful no-window 만 커버).
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const KEY = "e2e";

const core = <T = unknown>(channel: string, payload?: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (r) => (window as unknown as { __suji__: { invoke: (ch: string, d?: unknown) => unknown } }).__suji__
      .invoke(r.channel as string, r.payload as Record<string, unknown> | undefined),
    { channel, payload },
  ) as Promise<T>;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
  await page.waitForFunction(() => typeof (window as any).__suji__ !== "undefined", { timeout: 10000 });
  await core("window-state:clear", { key: KEY });
});

afterAll(async () => {
  try {
    await core("window-state:clear", { key: KEY });
  } catch {}
  await browser?.disconnect();
});

describe("window-state plugin: live window round-trip", () => {
  test("save reads live bounds and persists", async () => {
    const r = await core<{ result?: { ok?: boolean }; error?: string }>("window-state:save", { key: KEY });
    expect(r?.error).toBeUndefined();
    expect(r?.result?.ok).toBe(true);
  });

  test("get returns the persisted live bounds", async () => {
    const r = await core<{ result?: { state?: any } }>("window-state:get", { key: KEY });
    const s = r?.result?.state;
    expect(s).not.toBeNull();
    expect(typeof s.x).toBe("number");
    expect(typeof s.y).toBe("number");
    expect(s.width).toBeGreaterThan(0);
    expect(s.height).toBeGreaterThan(0);
    expect(typeof s.maximized).toBe("boolean");
  });

  test("restore applies stored state (restored:true)", async () => {
    const r = await core<{ result?: { restored?: boolean } }>("window-state:restore", { key: KEY });
    expect(r?.result?.restored).toBe(true);
  });

  test("clear removes state → get null, restore false", async () => {
    await core("window-state:clear", { key: KEY });
    const g = await core<{ result?: { state?: any } }>("window-state:get", { key: KEY });
    expect(g?.result?.state ?? null).toBeNull();
    const r = await core<{ result?: { restored?: boolean } }>("window-state:restore", { key: KEY });
    expect(r?.result?.restored).toBe(false);
  });
});
