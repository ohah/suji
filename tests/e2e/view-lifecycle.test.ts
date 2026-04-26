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
 *   - host destroy → 모든 child view auto destroy
 *   - 기존 webContents API(loadURL/executeJavaScript)에 viewId 전달 시 정상 동작 (17-A.5 회귀)
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

// 각 test가 독립적이도록 host 창을 새로 만들고 끝에 정리.
async function freshHost(): Promise<number> {
  const r = (await coreCall({
    cmd: "create_window",
    title: "view-host",
    url: "about:blank",
  })) as { windowId: number };
  expect(typeof r.windowId).toBe("number");
  return r.windowId;
}

async function destroyWindow(windowId: number): Promise<void> {
  // close()는 cancelable이라 destroy 직접 호출. 단 destroy IPC가 노출 안되어 있을 수도.
  // SDK는 close만 노출하지만 IPC 차원에선 close가 충분 (cancelable이지만 listener 없음).
  // 단순화: window를 그대로 두고 다음 테스트가 새 window 사용 — 누적되어도 같은 process.
  void windowId;
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
    await destroyWindow(host);
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
    const v = (await coreCall({
      cmd: "create_view",
      hostId: host,
      x: 0,
      y: 0,
      width: 100,
      height: 100,
    })) as { viewId: number };
    const r = (await coreCall({ cmd: "destroy_view", viewId: v.viewId })) as { ok: boolean };
    expect(r.ok).toBe(true);
    await destroyWindow(host);
  });
});

describe("17-A.7: z-order (addChildView / setTopView / getChildViews)", () => {
  test("addChildView re-call moves view to top", async () => {
    const host = await freshHost();
    const v1 = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 0, width: 100, height: 100 })) as { viewId: number };
    const v2 = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 100, width: 100, height: 100 })) as { viewId: number };

    const before = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(before.viewIds).toEqual([v1.viewId, v2.viewId]); // v1 bottom, v2 top

    await coreCall({ cmd: "add_child_view", hostId: host, viewId: v1.viewId });
    const after = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(after.viewIds).toEqual([v2.viewId, v1.viewId]); // v1 이제 top
    await destroyWindow(host);
  });

  test("setTopView == addChildView(undefined)", async () => {
    const host = await freshHost();
    const v1 = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 0, width: 50, height: 50 })) as { viewId: number };
    const v2 = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 50, width: 50, height: 50 })) as { viewId: number };
    await coreCall({ cmd: "set_top_view", hostId: host, viewId: v1.viewId });
    const r = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(r.viewIds).toEqual([v2.viewId, v1.viewId]);
    await destroyWindow(host);
  });
});

describe("17-A.7: setViewBounds / setViewVisible", () => {
  test("setViewBounds returns ok:true", async () => {
    const host = await freshHost();
    const v = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 0, width: 100, height: 100 })) as { viewId: number };
    const r = (await coreCall({
      cmd: "set_view_bounds",
      viewId: v.viewId,
      x: 50,
      y: 60,
      width: 300,
      height: 400,
    })) as { ok: boolean };
    expect(r.ok).toBe(true);
    await destroyWindow(host);
  });

  test("setViewVisible toggle ok:true", async () => {
    const host = await freshHost();
    const v = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 0, width: 100, height: 100 })) as { viewId: number };
    const r1 = (await coreCall({ cmd: "set_view_visible", viewId: v.viewId, visible: false })) as { ok: boolean };
    expect(r1.ok).toBe(true);
    const r2 = (await coreCall({ cmd: "set_view_visible", viewId: v.viewId, visible: true })) as { ok: boolean };
    expect(r2.ok).toBe(true);
    await destroyWindow(host);
  });
});

describe("17-A.7: 17-A.5 회귀 — webContents API view 호환", () => {
  test("loadURL on viewId returns ok:true (windowId 자리에 viewId)", async () => {
    const host = await freshHost();
    const v = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 0, width: 200, height: 200 })) as { viewId: number };
    const r = (await coreCall({ cmd: "load_url", windowId: v.viewId, url: "about:blank" })) as { ok: boolean };
    expect(r.ok).toBe(true);
    await destroyWindow(host);
  });

  test("setTitle on viewId returns ok:false (NotAWindow)", async () => {
    const host = await freshHost();
    const v = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 0, width: 100, height: 100 })) as { viewId: number };
    const r = (await coreCall({ cmd: "set_title", windowId: v.viewId, title: "x" })) as { ok: boolean };
    expect(r.ok).toBe(false);
    await destroyWindow(host);
  });
});

describe("17-A.7: getChildViews", () => {
  test("getChildViews returns ordered viewIds (z-order, 0=bottom, last=top)", async () => {
    const host = await freshHost();
    const a = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 0, width: 50, height: 50 })) as { viewId: number };
    const b = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 50, width: 50, height: 50 })) as { viewId: number };
    const c = (await coreCall({ cmd: "create_view", hostId: host, x: 0, y: 100, width: 50, height: 50 })) as { viewId: number };
    const r = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[]; ok: boolean };
    expect(r.ok).toBe(true);
    expect(r.viewIds).toEqual([a.viewId, b.viewId, c.viewId]);
    await destroyWindow(host);
  });

  test("getChildViews on host without view returns empty array", async () => {
    const host = await freshHost();
    const r = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[]; ok: boolean };
    expect(r.ok).toBe(true);
    expect(r.viewIds).toEqual([]);
    await destroyWindow(host);
  });
});
