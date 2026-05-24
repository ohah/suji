/**
 * powerSaveBlocker E2E — OS sleep/display inhibition handles.
 *
 * macOS: IOPMAssertionCreateWithName / IOPMAssertionRelease.
 * Linux: XScreenSaverSuspend over a live X11 display connection.
 * Windows: PowerCreateRequest / PowerSetRequest / PowerClearRequest.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { callCore, getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  callCore<T>(page, request);

async function startBlocker(type: "prevent_app_suspension" | "prevent_display_sleep") {
  const started = await core<{ id: number }>({
    cmd: "power_save_blocker_start",
    type,
  });
  expect(started.id).toBeGreaterThan(0);
  return started.id;
}

async function stopBlocker(id: number) {
  return core<{ success: boolean }>({
    cmd: "power_save_blocker_stop",
    id,
  });
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

describe("powerSaveBlocker", () => {
  test("prevent_display_sleep start -> stop", async () => {
    const id = await startBlocker("prevent_display_sleep");
    const stopped = await stopBlocker(id);
    expect(stopped.success).toBe(true);
  });

  test("prevent_app_suspension start -> stop", async () => {
    const id = await startBlocker("prevent_app_suspension");
    const stopped = await stopBlocker(id);
    expect(stopped.success).toBe(true);
  });

  test("stop(0) is false", async () => {
    const stopped = await stopBlocker(0);
    expect(stopped.success).toBe(false);
  });

  test("stopping the same id twice is false on the second stop", async () => {
    const id = await startBlocker("prevent_display_sleep");
    const first = await stopBlocker(id);
    expect(first.success).toBe(true);

    const second = await stopBlocker(id);
    expect(second.success).toBe(false);
  });

  test("multiple blockers have independent ids and stop independently", async () => {
    const displayId = await startBlocker("prevent_display_sleep");
    const appId = await startBlocker("prevent_app_suspension");
    expect(appId).not.toBe(displayId);

    const displayStopped = await stopBlocker(displayId);
    expect(displayStopped.success).toBe(true);

    const appStopped = await stopBlocker(appId);
    expect(appStopped.success).toBe(true);

    const displayAgain = await stopBlocker(displayId);
    expect(displayAgain.success).toBe(false);
  });
});
