/**
 * Phase 4-B Zoom E2E — `windows.{setZoomLevel, setZoomFactor, getZoomLevel, getZoomFactor}`.
 *
 * CEF는 zoomLevel + zoomFactor 두 표현 — Electron 호환.
 *   factor = 1.2^level (또는 역으로 level = log_1.2(factor))
 *
 * 실행: tests/e2e/run-zoom.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;
let windowId: number;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

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

  // multi-backend 첫 창의 windowId — 보통 1
  windowId = 1;
});

afterAll(async () => {
  // reset zoom
  try { await core({ cmd: "set_zoom_level", windowId, level: 0 }); } catch {}
  await browser?.disconnect();
});

describe("setZoomLevel / getZoomLevel — round-trip", () => {
  test("level 0 (default) → set/get 일치", async () => {
    const set = await core<{ ok: boolean }>({ cmd: "set_zoom_level", windowId, level: 0 });
    expect(set).toBeDefined();
    const get = await core<{ level: number }>({ cmd: "get_zoom_level", windowId });
    expect(Math.abs(get.level - 0)).toBeLessThan(0.01);
  });

  test("level 1.5 → 양수 zoom in", async () => {
    await core({ cmd: "set_zoom_level", windowId, level: 1.5 });
    const get = await core<{ level: number }>({ cmd: "get_zoom_level", windowId });
    expect(Math.abs(get.level - 1.5)).toBeLessThan(0.01);
  });

  test("level -1.5 → 음수 zoom out", async () => {
    await core({ cmd: "set_zoom_level", windowId, level: -1.5 });
    const get = await core<{ level: number }>({ cmd: "get_zoom_level", windowId });
    expect(Math.abs(get.level - (-1.5))).toBeLessThan(0.01);
  });

  test("level 0 (reset)", async () => {
    await core({ cmd: "set_zoom_level", windowId, level: 0 });
    const get = await core<{ level: number }>({ cmd: "get_zoom_level", windowId });
    expect(Math.abs(get.level - 0)).toBeLessThan(0.01);
  });
});

describe("setZoomFactor / getZoomFactor — round-trip", () => {
  test("factor 1.0 (default) → set/get 일치", async () => {
    await core({ cmd: "set_zoom_factor", windowId, factor: 1.0 });
    const get = await core<{ factor: number }>({ cmd: "get_zoom_factor", windowId });
    expect(Math.abs(get.factor - 1.0)).toBeLessThan(0.01);
  });

  test("factor 1.5 → 큰 폰트", async () => {
    await core({ cmd: "set_zoom_factor", windowId, factor: 1.5 });
    const get = await core<{ factor: number }>({ cmd: "get_zoom_factor", windowId });
    expect(Math.abs(get.factor - 1.5)).toBeLessThan(0.01);
  });

  test("factor 0.75 → 작은 폰트", async () => {
    await core({ cmd: "set_zoom_factor", windowId, factor: 0.75 });
    const get = await core<{ factor: number }>({ cmd: "get_zoom_factor", windowId });
    expect(Math.abs(get.factor - 0.75)).toBeLessThan(0.01);
  });
});

describe("level ↔ factor 관계 (factor = 1.2^level)", () => {
  test("level 1.0 → factor ≈ 1.2", async () => {
    await core({ cmd: "set_zoom_level", windowId, level: 1.0 });
    const get = await core<{ factor: number }>({ cmd: "get_zoom_factor", windowId });
    // CEF: factor = 1.2^level. level=1 → factor=1.2
    expect(Math.abs(get.factor - 1.2)).toBeLessThan(0.05);
  });

  test("level 0 → factor ≈ 1.0", async () => {
    await core({ cmd: "set_zoom_level", windowId, level: 0 });
    const get = await core<{ factor: number }>({ cmd: "get_zoom_factor", windowId });
    expect(Math.abs(get.factor - 1.0)).toBeLessThan(0.05);
  });
});

describe("error / 잘못된 windowId", () => {
  test("set_zoom_level 잘못된 windowId — 응답 형식 유지", async () => {
    const r = await core<any>({ cmd: "set_zoom_level", windowId: 99999, level: 1.0 });
    expect(r).toBeDefined();
  });

  test("get_zoom_factor 잘못된 windowId — fallback 응답", async () => {
    const r = await core<{ factor?: number }>({ cmd: "get_zoom_factor", windowId: 99999 });
    expect(r).toBeDefined();
  });
});
