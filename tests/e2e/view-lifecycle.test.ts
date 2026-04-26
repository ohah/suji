/**
 * WebContentsView Lifecycle E2E Tests (Phase 17-A.7)
 *
 * host 창에 child view들을 합성하고 z-order/lifecycle/webContents 호환을 검증.
 *
 * 실행 방법:
 *   bash tests/e2e/run-view-lifecycle.sh
 *
 * 범위:
 *   - createView → host 안에 child NSView + CefBrowser 합성
 *   - addChildView/setTopView/getChildViews — z-order 매트릭스
 *   - setViewBounds/setViewVisible — 위치/표시 제어
 *   - destroyView → window:view-destroyed 이벤트 도달
 *   - 기존 webContents API(loadURL/setTitle)에 viewId 전달 시 정상 동작 (17-A.5 회귀)
 *
 * NOTE: host 창은 close_window IPC가 아직 노출되지 않아 테스트 간 누적된다 (puppeteer
 *       세션 종료 시 함께 정리). host destroy → child auto-destroy 검증은 17-B에서
 *       close_window 노출 후 추가.
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

type CoreResponse = Record<string, unknown> & { from: string; cmd: string };

const coreCall = (request: object): Promise<CoreResponse> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request,
  ) as Promise<CoreResponse>;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 10000,
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  const main = pages.find((p) => p.url().startsWith("http://localhost"));
  if (!main) throw new Error("main window (localhost) not found in puppeteer pages");
  page = main;
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

async function freshHost(): Promise<number> {
  const r = (await coreCall({
    cmd: "create_window",
    title: "view-host",
    url: "about:blank",
  })) as { windowId: number };
  expect(typeof r.windowId).toBe("number");
  return r.windowId;
}

/** view 생성 + viewId 추출 — `(await coreCall({...})) as {viewId}` 보일러를 한 줄로. */
async function mkView(
  hostId: number,
  bounds: { x?: number; y?: number; width?: number; height?: number } = {},
): Promise<number> {
  const r = (await coreCall({
    cmd: "create_view",
    hostId,
    x: bounds.x ?? 0,
    y: bounds.y ?? 0,
    width: bounds.width ?? 100,
    height: bounds.height ?? 100,
  })) as { viewId: number };
  return r.viewId;
}

describe("17-A.7: createView / destroyView", () => {
  test("createView returns viewId in monotonic id pool", async () => {
    const host = await freshHost();
    const r = (await coreCall({
      cmd: "create_view",
      hostId: host,
      url: "about:blank",
      x: 0,
      y: 0,
      width: 200,
      height: 200,
    })) as { viewId: number; cmd: string };
    expect(r.cmd).toBe("create_view");
    expect(typeof r.viewId).toBe("number");
    expect(r.viewId).toBeGreaterThan(host);
  });

  test("createView with non-existent host returns error", async () => {
    const r = (await coreCall({
      cmd: "create_view",
      hostId: 99999,
      url: "about:blank",
      x: 0,
      y: 0,
      width: 100,
      height: 100,
    })) as { error?: string };
    expect(r.error).toBe("failed");
  });

  test("destroyView returns ok:true", async () => {
    const host = await freshHost();
    const view = await mkView(host);
    const r = (await coreCall({ cmd: "destroy_view", viewId: view })) as { ok: boolean };
    expect(r.ok).toBe(true);
  });
});

describe("17-A.7: z-order (addChildView / setTopView / getChildViews)", () => {
  test("addChildView re-call moves view to top", async () => {
    const host = await freshHost();
    const v1 = await mkView(host);
    const v2 = await mkView(host, { y: 100 });

    const before = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(before.viewIds).toEqual([v1, v2]);

    await coreCall({ cmd: "add_child_view", hostId: host, viewId: v1 });
    const after = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(after.viewIds).toEqual([v2, v1]);
  });

  test("setTopView == addChildView(undefined)", async () => {
    const host = await freshHost();
    const v1 = await mkView(host, { width: 50, height: 50 });
    const v2 = await mkView(host, { y: 50, width: 50, height: 50 });
    await coreCall({ cmd: "set_top_view", hostId: host, viewId: v1 });
    const r = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(r.viewIds).toEqual([v2, v1]);
  });
});

describe("17-A.7: setViewBounds / setViewVisible", () => {
  test("setViewBounds returns ok:true", async () => {
    const host = await freshHost();
    const view = await mkView(host);
    const r = (await coreCall({
      cmd: "set_view_bounds",
      viewId: view,
      x: 50,
      y: 60,
      width: 300,
      height: 400,
    })) as { ok: boolean };
    expect(r.ok).toBe(true);
  });

  test("setViewVisible toggle ok:true", async () => {
    const host = await freshHost();
    const view = await mkView(host);
    const r1 = (await coreCall({ cmd: "set_view_visible", viewId: view, visible: false })) as { ok: boolean };
    expect(r1.ok).toBe(true);
    const r2 = (await coreCall({ cmd: "set_view_visible", viewId: view, visible: true })) as { ok: boolean };
    expect(r2.ok).toBe(true);
  });
});

describe("17-A.7: 17-A.5 회귀 — webContents API view 호환", () => {
  test("loadURL on viewId returns ok:true (windowId 자리에 viewId)", async () => {
    const host = await freshHost();
    const view = await mkView(host, { width: 200, height: 200 });
    const r = (await coreCall({ cmd: "load_url", windowId: view, url: "about:blank" })) as { ok: boolean };
    expect(r.ok).toBe(true);
  });

  test("setTitle on viewId returns ok:false (NotAWindow)", async () => {
    const host = await freshHost();
    const view = await mkView(host);
    const r = (await coreCall({ cmd: "set_title", windowId: view, title: "x" })) as { ok: boolean };
    expect(r.ok).toBe(false);
  });
});

describe("17-A.7: getChildViews", () => {
  test("getChildViews returns ordered viewIds (z-order, 0=bottom, last=top)", async () => {
    const host = await freshHost();
    const a = await mkView(host, { width: 50, height: 50 });
    const b = await mkView(host, { y: 50, width: 50, height: 50 });
    const c = await mkView(host, { y: 100, width: 50, height: 50 });
    const r = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[]; ok: boolean };
    expect(r.ok).toBe(true);
    expect(r.viewIds).toEqual([a, b, c]);
  });

  test("getChildViews on host without view returns empty array", async () => {
    const host = await freshHost();
    const r = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[]; ok: boolean };
    expect(r.ok).toBe(true);
    expect(r.viewIds).toEqual([]);
  });
});
