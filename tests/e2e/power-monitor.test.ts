/**
 * powerMonitor E2E — OS idle time/state.
 *
 * macOS: CGEventSourceSecondsSinceLastEventType.
 * Linux: XScreenSaverQueryInfo over X11/Xvfb.
 * Windows: GetLastInputInfo.
 */
import { beforeAll, afterAll, describe, expect, test } from "bun:test";
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

describe("powerMonitor idle", () => {
  test("getSystemIdleTime returns finite non-negative seconds", async () => {
    const r = await core<{ seconds: number }>({ cmd: "power_monitor_get_idle_time" });
    expect(typeof r.seconds).toBe("number");
    expect(Number.isFinite(r.seconds)).toBe(true);
    expect(r.seconds).toBeGreaterThanOrEqual(0);
  });

  test("threshold=0 reports idle", async () => {
    const r = await core<{ state: string }>({ cmd: "power_monitor_get_idle_state", threshold: 0 });
    expect(r.state).toBe("idle");
  });

  test("threshold above current idle time reports active unless locked", async () => {
    const cur = await core<{ seconds: number }>({ cmd: "power_monitor_get_idle_time" });
    const r = await core<{ state: string }>({
      cmd: "power_monitor_get_idle_state",
      threshold: Math.ceil(cur.seconds) + 1000,
    });
    expect(["active", "locked"]).toContain(r.state);
  });
});
