/**
 * app.setBadgeCount E2E — Electron-style app badge state.
 *
 * macOS maps to NSDockTile. Linux/Windows native visual badges are best-effort
 * because CI runners may not expose Unity/Explorer taskbar services, so this
 * test fixes the runtime contract: command succeeds, count round-trips, and
 * native backend availability is reported as a boolean.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { callCore, getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  callCore<T>(page, request);

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("app.setBadgeCount", () => {
  test("set -> get round-trip reports native backend status", async () => {
    const set = await core<{ success: boolean; native: boolean }>({
      cmd: "app_set_badge_count",
      count: 11,
    });
    expect(set.success).toBe(true);
    expect(typeof set.native).toBe("boolean");

    const count = await core<{ count: number }>({ cmd: "app_get_badge_count" });
    expect(count.count).toBe(11);
  });

  test("zero clears count", async () => {
    await core({ cmd: "app_set_badge_count", count: 4 });
    const set = await core<{ success: boolean; native: boolean }>({
      cmd: "app_set_badge_count",
      count: 0,
    });
    expect(set.success).toBe(true);
    expect(typeof set.native).toBe("boolean");

    const count = await core<{ count: number }>({ cmd: "app_get_badge_count" });
    expect(count.count).toBe(0);
  });

  test("negative count clamps to zero", async () => {
    const set = await core<{ success: boolean; native: boolean }>({
      cmd: "app_set_badge_count",
      count: -1,
    });
    expect(set.success).toBe(true);
    expect(typeof set.native).toBe("boolean");

    const count = await core<{ count: number }>({ cmd: "app_get_badge_count" });
    expect(count.count).toBe(0);
  });
});
