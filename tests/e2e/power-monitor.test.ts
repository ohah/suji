/**
 * powerMonitor E2E — OS idle time/state + event dispatch path.
 *
 * macOS: CGEventSourceSecondsSinceLastEventType.
 * Linux: XScreenSaverQueryInfo over X11/Xvfb.
 * Windows: GetLastInputInfo.
 *
 * Event watcher sources:
 * macOS NSWorkspace notifications, Linux logind/ScreenSaver DBus signals,
 * Windows WM_POWERBROADCAST/WTS session messages. CI cannot force real system
 * suspend/lock, so this test uses SUJI_E2E_POWER_MONITOR_TEST_HOOK to exercise
 * the same native callback -> EventBus -> renderer listener path.
 */
import { beforeAll, afterAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { callCore, getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  callCore<T>(page, request);

async function startCollect<T = any>(channel: string): Promise<{ stop: (timeoutMs: number) => Promise<T[]> }> {
  const id = await page.evaluate((ch: string) => {
    const events: any[] = [];
    const off = (window as any).__suji__.on(ch, (payload: any) => {
      events.push(payload);
    });
    const reg = ((window as any).__power_monitor_events__ ||= {});
    const k = String(Math.random());
    reg[k] = { events, off };
    return k;
  }, channel);
  return {
    stop: (timeoutMs: number) => page.evaluate(async ({ k, timeoutMs }: { k: string; timeoutMs: number }) => {
      await new Promise((r) => setTimeout(r, timeoutMs));
      const reg = (window as any).__power_monitor_events__;
      const c = reg[k];
      c.off();
      const events = c.events.slice();
      delete reg[k];
      return events;
    }, { k: id, timeoutMs }),
  };
}

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

describe("powerMonitor events", () => {
  for (const event of ["suspend", "resume", "lock-screen", "unlock-screen"] as const) {
    test(`power:${event} reaches renderer listener`, async () => {
      const collector = await startCollect(`power:${event}`);
      const r = await core<{ success: boolean }>({ cmd: "power_monitor_test_emit", event });
      expect(r.success).toBe(true);
      const events = await collector.stop(300);
      expect(events.length).toBe(1);
      expect(events[0]).toEqual({});
    });
  }

  test("lock-screen/unlock-screen updates getSystemIdleState locked priority", async () => {
    const lock = await core<{ success: boolean }>({ cmd: "power_monitor_test_emit", event: "lock-screen" });
    expect(lock.success).toBe(true);
    const locked = await core<{ state: string }>({ cmd: "power_monitor_get_idle_state", threshold: 999999 });
    expect(locked.state).toBe("locked");

    const unlock = await core<{ success: boolean }>({ cmd: "power_monitor_test_emit", event: "unlock-screen" });
    expect(unlock.success).toBe(true);
    const unlocked = await core<{ state: string }>({ cmd: "power_monitor_get_idle_state", threshold: 999999 });
    expect(unlocked.state).toBe("active");
  });

  test("test hook rejects unknown event names", async () => {
    const r = await core<{ success: boolean }>({ cmd: "power_monitor_test_emit", event: "bad-event" });
    expect(r.success).toBe(false);
  });
});
