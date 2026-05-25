/**
 * Screen runtime E2E — Electron `screen` 호환 IPC.
 *
 * Linux Actions에서는 Xvfb의 X11 screen을 통해 `getAllDisplays`,
 * `getCursorScreenPoint`, `getDisplayNearestPoint`가 실제 display 정보를
 * 반환하는지 검증한다. macOS에서도 같은 테스트가 NSScreen 경로를 검증한다.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

type Display = {
  index: number;
  isPrimary: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
  visibleX: number;
  visibleY: number;
  visibleWidth: number;
  visibleHeight: number;
  scaleFactor: number;
};

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

describe("screen runtime APIs", () => {
  test("getAllDisplays returns at least one display with Electron-like fields", async () => {
    const r = await core<{ displays: Display[] }>({ cmd: "screen_get_all_displays" });
    expect(Array.isArray(r.displays)).toBe(true);
    expect(r.displays.length).toBeGreaterThan(0);

    for (const display of r.displays) {
      expect(typeof display.index).toBe("number");
      expect(typeof display.isPrimary).toBe("boolean");
      expect(Number.isFinite(display.x)).toBe(true);
      expect(Number.isFinite(display.y)).toBe(true);
      expect(display.width).toBeGreaterThan(0);
      expect(display.height).toBeGreaterThan(0);
      expect(display.visibleWidth).toBeGreaterThan(0);
      expect(display.visibleHeight).toBeGreaterThan(0);
      expect(display.scaleFactor).toBeGreaterThan(0);
    }

    expect(r.displays.some((display) => display.isPrimary)).toBe(true);
  });

  test("getDisplayNearestPoint returns a display for the primary center", async () => {
    const displays = (await core<{ displays: Display[] }>({ cmd: "screen_get_all_displays" })).displays;
    const primary = displays.find((display) => display.isPrimary) ?? displays[0];
    const r = await core<{ index: number }>({
      cmd: "screen_get_display_nearest_point",
      x: primary.x + primary.width / 2,
      y: primary.y + primary.height / 2,
    });
    expect(r.index).toBeGreaterThanOrEqual(0);
  });

  test("getDisplayNearestPoint returns -1 outside every display", async () => {
    const r = await core<{ index: number }>({
      cmd: "screen_get_display_nearest_point",
      x: -999999,
      y: -999999,
    });
    expect(r.index).toBe(-1);
  });

  test("getCursorScreenPoint returns finite coordinates", async () => {
    const r = await core<{ x: number; y: number }>({ cmd: "screen_get_cursor_point" });
    expect(Number.isFinite(r.x)).toBe(true);
    expect(Number.isFinite(r.y)).toBe(true);
  });
});
