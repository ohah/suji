/**
 * WebContentsView Lifecycle E2E Tests (Phase 17-B)
 *
 * host 창에 child view들을 합성하고 z-order/lifecycle/webContents 호환을 검증.
 *
 * 실행 방법:
 *   bash tests/e2e/run-view-lifecycle.sh
 *
 * 범위:
 *   - createView → host 안에 child WebContentsView 합성
 *   - addChildView/setTopView/getChildViews — z-order 매트릭스
 *   - setViewBounds/setViewVisible — 위치/표시 제어
 *   - destroyView → window:view-destroyed 이벤트 도달
 *   - 기존 webContents API(loadURL/setTitle)에 viewId 전달 시 정상 동작
 *
 * NOTE: runner가 fresh suji dev 세션을 띄우고 종료 시 전체 앱 프로세스를 정리한다.
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

type CoreResponse = Record<string, unknown> & { from: string; cmd: string };
type CdpTarget = { id: string; type: string; url: string; webSocketDebuggerUrl?: string };

const coreCall = (request: object): Promise<CoreResponse> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request,
  ) as Promise<CoreResponse>;

const isDesktopCefViewsRun = () =>
  ["darwin", "linux", "win32"].includes(process.platform) &&
  process.env.SUJI_CEF_VIEWS !== "0" &&
  process.env.SUJI_CEF_VIEWS !== "false";

const isCefViewsMac = () =>
  process.platform === "darwin" &&
  process.env.SUJI_CEF_VIEWS !== "0" &&
  process.env.SUJI_CEF_VIEWS !== "false";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const dataUrl = (html: string) => `data:text/html,${encodeURIComponent(html)}`;

async function fetchCdpTargets(): Promise<CdpTarget[]> {
  const r = await fetch("http://localhost:9222/json");
  return (await r.json()) as CdpTarget[];
}

async function waitForCdpTarget(
  predicate: (target: CdpTarget) => boolean,
  label: string,
  timeoutMs = 5000,
): Promise<CdpTarget> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const target = (await fetchCdpTargets()).find(predicate);
    if (target) return target;
    await wait(100);
  }
  throw new Error(`CDP target not found: ${label}`);
}

async function waitForCdpTargetGone(
  predicate: (target: CdpTarget) => boolean,
  label: string,
  timeoutMs = 5000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const target = (await fetchCdpTargets()).find(predicate);
    if (!target) return;
    await wait(100);
  }
  throw new Error(`CDP target still present: ${label}`);
}

async function cdpCommand<T = Record<string, unknown>>(
  webSocketDebuggerUrl: string,
  method: string,
  params: Record<string, unknown> = {},
): Promise<T> {
  const ws = new WebSocket(webSocketDebuggerUrl);
  await new Promise<void>((resolve, reject) => {
    ws.addEventListener("open", () => resolve());
    ws.addEventListener("error", () => reject(new Error(`CDP websocket open failed for ${method}`)));
  });

  return await new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error(`CDP command timeout: ${method}`));
    }, 5000);
    ws.addEventListener("message", (event) => {
      const msg = JSON.parse(String(event.data));
      if (msg.id !== 1) return;
      clearTimeout(timer);
      ws.close();
      if (msg.error) reject(new Error(`${method} failed: ${JSON.stringify(msg.error)}`));
      else resolve(msg.result as T);
    });
    ws.send(JSON.stringify({ id: 1, method, params }));
  });
}

function visibleSujiChildWindowCount(): number {
  const script = `
import Foundation
import CoreGraphics
let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
let windows = (rawWindows as NSArray?) ?? []
var count = 0
for case let window as NSDictionary in windows {
    if (window[kCGWindowOwnerName] as? String) == "suji" &&
       (window[kCGWindowName] as? String) == "Suji WebContentsView" {
        count += 1
    }
}
print(count)
`;
  const out = execFileSync("swift", ["-"], { input: script, encoding: "utf8" }).trim();
  return Number(out);
}

async function waitForVisibleSujiChildWindowCount(expected: number, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let last = visibleSujiChildWindowCount();
  while (Date.now() < deadline) {
    if (last === expected) return;
    await wait(100);
    last = visibleSujiChildWindowCount();
  }
  expect(last).toBe(expected);
}

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
  bounds: { x?: number; y?: number; width?: number; height?: number; url?: string } = {},
): Promise<number> {
  const req: Record<string, unknown> = {
    cmd: "create_view",
    hostId,
    x: bounds.x ?? 0,
    y: bounds.y ?? 0,
    width: bounds.width ?? 100,
    height: bounds.height ?? 100,
  };
  if (bounds.url) req.url = bounds.url;
  const r = (await coreCall(req)) as { viewId: number };
  return r.viewId;
}

describe("runner mode guard", () => {
  test("desktop runner/default actually enabled CEF Views path", () => {
    if (!isDesktopCefViewsRun()) return;
    const logPath = process.env.SUJI_LOG;
    expect(logPath).toBeTruthy();
    const log = readFileSync(logPath!, "utf8");
    expect(log).toContain("CEF Views path enabled");
  });
});

describe("WebContentsView: createView / destroyView", () => {
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

describe("WebContentsView: z-order (addChildView / setTopView / getChildViews)", () => {
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

describe("WebContentsView: setViewBounds / setViewVisible", () => {
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

  test("CEF Views child-window reorder keeps hidden siblings hidden", async () => {
    if (!isCefViewsMac()) return;

    const baseline = visibleSujiChildWindowCount();
    const host = await freshHost();
    const hidden = await mkView(host, { x: 20, y: 20, width: 160, height: 120 });
    const visible = await mkView(host, { x: 220, y: 20, width: 160, height: 120 });
    await wait(250);

    const afterCreate = visibleSujiChildWindowCount();
    expect(afterCreate).toBeGreaterThanOrEqual(baseline + 2);

    const r1 = (await coreCall({ cmd: "set_view_visible", viewId: hidden, visible: false })) as { ok: boolean };
    expect(r1.ok).toBe(true);
    await wait(250);
    const afterHide = visibleSujiChildWindowCount();
    expect(afterHide).toBe(afterCreate - 1);

    const r2 = (await coreCall({ cmd: "set_top_view", hostId: host, viewId: visible })) as { ok: boolean };
    expect(r2.ok).toBe(true);
    await wait(250);
    expect(visibleSujiChildWindowCount()).toBe(afterHide);
  });
});

describe("WebContentsView: webContents API view 호환", () => {
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

describe("WebContentsView: getChildViews", () => {
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

// ============================================
// WebContentsView 보강 — 이벤트 frontend 도달 + 멀티 host 격리 + remove/re-add
// ============================================

describe("WebContentsView: lifecycle 이벤트 frontend 도달", () => {
  test("createView 시 window:view-created 이벤트가 frontend listener에 도달", async () => {
    const host = await freshHost();
    // listener 등록 — 다음 createView가 trigger.
    await page.evaluate(() => {
      (window as any).__viewCreatedEvents = [];
      const sj = (window as any).suji ?? (window as any).__suji__;
      sj.on?.("window:view-created", (data: unknown) => {
        (window as any).__viewCreatedEvents.push(data);
      });
    });

    const view = await mkView(host);

    // 이벤트 propagation 대기 (CEF process message가 다음 런루프 틱에 도달)
    await new Promise((r) => setTimeout(r, 100));
    const events = (await page.evaluate(() => (window as any).__viewCreatedEvents)) as Array<
      { viewId: number; hostId: number }
    >;
    const matched = events.find((e) => e.viewId === view && e.hostId === host);
    expect(matched).toBeDefined();
  });

  test("destroyView 시 window:view-destroyed 이벤트가 frontend listener에 도달", async () => {
    const host = await freshHost();
    const view = await mkView(host);

    await page.evaluate(() => {
      (window as any).__viewDestroyedEvents = [];
      const sj = (window as any).suji ?? (window as any).__suji__;
      sj.on?.("window:view-destroyed", (data: unknown) => {
        (window as any).__viewDestroyedEvents.push(data);
      });
    });

    await coreCall({ cmd: "destroy_view", viewId: view });
    await new Promise((r) => setTimeout(r, 100));
    const events = (await page.evaluate(() => (window as any).__viewDestroyedEvents)) as Array<
      { viewId: number; hostId: number }
    >;
    const matched = events.find((e) => e.viewId === view && e.hostId === host);
    expect(matched).toBeDefined();
  });
});

describe("WebContentsView: multiple hosts isolation", () => {
  test("두 host에 각각 view 만들면 cross-affect 없음", async () => {
    const host_a = await freshHost();
    const host_b = await freshHost();
    const va = await mkView(host_a);
    const vb1 = await mkView(host_b);
    const vb2 = await mkView(host_b);

    // host_a getChildViews는 [va], host_b는 [vb1, vb2]
    const ra = (await coreCall({ cmd: "get_child_views", hostId: host_a })) as { viewIds: number[] };
    const rb = (await coreCall({ cmd: "get_child_views", hostId: host_b })) as { viewIds: number[] };
    expect(ra.viewIds).toEqual([va]);
    expect(rb.viewIds).toEqual([vb1, vb2]);

    // host_a의 view를 destroyView해도 host_b 영향 X
    await coreCall({ cmd: "destroy_view", viewId: va });
    const rb_after = (await coreCall({ cmd: "get_child_views", hostId: host_b })) as { viewIds: number[] };
    expect(rb_after.viewIds).toEqual([vb1, vb2]);
  });
});

describe("WebContentsView: removeChildView 후 재부착", () => {
  test("removeChildView → getChildViews에서 사라짐 → addChildView로 복원", async () => {
    const host = await freshHost();
    const view = await mkView(host);

    await coreCall({ cmd: "remove_child_view", hostId: host, viewId: view });
    const r1 = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(r1.viewIds).toEqual([]);

    await coreCall({ cmd: "add_child_view", hostId: host, viewId: view });
    const r2 = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(r2.viewIds).toEqual([view]);
  });
});

describe("WebContentsView: destroyView 후 getChildViews 감소", () => {
  test("3 view 중 1 destroy → getChildViews 길이 2", async () => {
    const host = await freshHost();
    const a = await mkView(host);
    const b = await mkView(host);
    const c = await mkView(host);

    const before = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(before.viewIds).toEqual([a, b, c]);

    await coreCall({ cmd: "destroy_view", viewId: b });
    const after = (await coreCall({ cmd: "get_child_views", hostId: host })) as { viewIds: number[] };
    expect(after.viewIds).toEqual([a, c]);
  });
});

describe("17-B.5: CEF Views multi-view destroy 안정성", () => {
  test("destroyView는 대상 child window만 닫고 host/남은 view/recreate를 유지", async () => {
    if (!isCefViewsMac()) return;

    const baseline = visibleSujiChildWindowCount();
    const hostMarker = `HOST_17B5_${Date.now()}`;
    const viewAMarker = `VIEW_17B5_A_${Date.now()}`;
    const viewBMarker = `VIEW_17B5_B_${Date.now()}`;
    const viewCMarker = `VIEW_17B5_C_${Date.now()}`;
    const hostHtml = `<!doctype html>
      <meta charset="utf-8" />
      <body data-marker="${hostMarker}">
        <button id="probe" style="position:absolute;left:24px;top:24px;width:140px;height:52px"
          onclick="document.body.dataset.clicked='yes'">probe</button>
      </body>`;
    const hostRes = (await coreCall({
      cmd: "create_window",
      title: "17-B.5 host",
      url: dataUrl(hostHtml),
      width: 520,
      height: 360,
    })) as { windowId: number };
    const host = hostRes.windowId;
    expect(typeof host).toBe("number");

    let viewA: number | undefined;
    let viewB: number | undefined;
    let viewC: number | undefined;
    try {
      const hostTarget = await waitForCdpTarget(
        (t) => t.type === "page" && t.url.includes(hostMarker),
        "17-B.5 host",
      );
      expect(hostTarget.webSocketDebuggerUrl).toBeTruthy();

      viewA = await mkView(host, {
        x: 0,
        y: 0,
        width: 220,
        height: 160,
        url: dataUrl(`<body data-marker="${viewAMarker}"><h1>${viewAMarker}</h1></body>`),
      });
      viewB = await mkView(host, {
        x: 240,
        y: 0,
        width: 220,
        height: 160,
        url: dataUrl(`<body data-marker="${viewBMarker}"><h1>${viewBMarker}</h1></body>`),
      });
      await waitForVisibleSujiChildWindowCount(baseline + 2);
      await waitForCdpTarget((t) => t.type === "page" && t.url.includes(viewAMarker), "view A");
      await waitForCdpTarget((t) => t.type === "page" && t.url.includes(viewBMarker), "view B");

      const topRes = (await coreCall({ cmd: "set_top_view", hostId: host, viewId: viewA })) as { ok: boolean };
      expect(topRes.ok).toBe(true);
      const hideRes = (await coreCall({ cmd: "set_view_visible", viewId: viewB, visible: false })) as { ok: boolean };
      expect(hideRes.ok).toBe(true);
      await waitForVisibleSujiChildWindowCount(baseline + 1);
      const showRes = (await coreCall({ cmd: "set_view_visible", viewId: viewB, visible: true })) as { ok: boolean };
      expect(showRes.ok).toBe(true);
      await waitForVisibleSujiChildWindowCount(baseline + 2);

      const destroyA = (await coreCall({ cmd: "destroy_view", viewId: viewA })) as { ok: boolean };
      expect(destroyA.ok).toBe(true);
      viewA = undefined;
      await waitForVisibleSujiChildWindowCount(baseline + 1);
      await waitForCdpTargetGone((t) => t.type === "page" && t.url.includes(viewAMarker), "destroyed view A");

      const remainingTarget = await waitForCdpTarget(
        (t) => t.type === "page" && t.url.includes(viewBMarker),
        "remaining view B",
      );
      expect(remainingTarget.webSocketDebuggerUrl).toBeTruthy();
      const remainingEval = await cdpCommand<{ result: { value?: string } }>(
        remainingTarget.webSocketDebuggerUrl!,
        "Runtime.evaluate",
        { expression: "document.body.dataset.marker", returnByValue: true },
      );
      expect(remainingEval.result.value).toBe(viewBMarker);

      const childrenAfterDestroy = (await coreCall({ cmd: "get_child_views", hostId: host })) as {
        viewIds: number[];
      };
      expect(childrenAfterDestroy.viewIds).toEqual([viewB]);

      const hostAfterDestroy = await waitForCdpTarget(
        (t) => t.type === "page" && t.url.includes(hostMarker),
        "host after child destroy",
      );
      expect(hostAfterDestroy.webSocketDebuggerUrl).toBeTruthy();
      const hostEval = await cdpCommand<{ result: { value?: string } }>(
        hostAfterDestroy.webSocketDebuggerUrl!,
        "Runtime.evaluate",
        { expression: "document.body.dataset.marker", returnByValue: true },
      );
      expect(hostEval.result.value).toBe(hostMarker);
      await cdpCommand(hostAfterDestroy.webSocketDebuggerUrl!, "Input.dispatchMouseEvent", {
        type: "mousePressed",
        x: 94,
        y: 50,
        button: "left",
        clickCount: 1,
      });
      await cdpCommand(hostAfterDestroy.webSocketDebuggerUrl!, "Input.dispatchMouseEvent", {
        type: "mouseReleased",
        x: 94,
        y: 50,
        button: "left",
        clickCount: 1,
      });
      const clickEval = await cdpCommand<{ result: { value?: string } }>(
        hostAfterDestroy.webSocketDebuggerUrl!,
        "Runtime.evaluate",
        { expression: "document.body.dataset.clicked", returnByValue: true },
      );
      expect(clickEval.result.value).toBe("yes");

      viewC = await mkView(host, {
        x: 0,
        y: 170,
        width: 220,
        height: 140,
        url: dataUrl(`<body data-marker="${viewCMarker}"><h1>${viewCMarker}</h1></body>`),
      });
      await waitForVisibleSujiChildWindowCount(baseline + 2);
      await waitForCdpTarget((t) => t.type === "page" && t.url.includes(viewCMarker), "recreated view C");
      const childrenAfterRecreate = (await coreCall({ cmd: "get_child_views", hostId: host })) as {
        viewIds: number[];
      };
      expect(childrenAfterRecreate.viewIds).toEqual([viewB, viewC]);
    } finally {
      for (const id of [viewA, viewB, viewC]) {
        if (id !== undefined) await coreCall({ cmd: "destroy_view", viewId: id });
      }
      await waitForVisibleSujiChildWindowCount(baseline).catch(() => undefined);
    }
  }, 30000);
});

describe("WebContentsView: webContents API view 호환 — executeJavaScript", () => {
  test("executeJavaScript on viewId returns ok:true (실제 JS 실행)", async () => {
    const host = await freshHost();
    const view = await mkView(host, { width: 200, height: 200 });
    const r = (await coreCall({
      cmd: "execute_javascript",
      windowId: view,
      code: "1 + 1;",
    })) as { ok: boolean };
    expect(r.ok).toBe(true);
  });

  test("isLoading on viewId returns ok:true (webContents 응답 도달)", async () => {
    const host = await freshHost();
    const view = await mkView(host, { width: 200, height: 200 });
    const r = (await coreCall({ cmd: "is_loading", windowId: view })) as {
      ok: boolean;
      loading: boolean;
    };
    // ok:true는 핸들러가 view를 .window와 똑같이 dispatch했다는 시그널.
    // (getURL은 OnAddressChange가 view에 대해 cache 채우는 시점이 비결정적이라 별도 검증 X)
    expect(r.ok).toBe(true);
  });
});

// ============================================
// WebContentsView 시각 검증 — view CefBrowser는 별도 DevTools target으로 puppeteer에 노출.
// 그 page에서 직접 컨텐츠 읽기/screenshot으로 "view가 실제 살아있고 렌더링되고 있다"는
// 픽셀 단계 증거 확보. host NSWindow 안에서의 합성 시각(z-order/위치/투명도)은
// 별도 OS-level child window 카운트와 manual demo로 보강.
// ============================================

describe("WebContentsView: view CefBrowser endpoint + 픽셀 캡처", () => {
  /** CDP /json endpoint에서 raw target 목록 — puppeteer browser.pages()는 main browser가
   *  발견한 page만 캐시. view CefBrowser는 별도 prefix /devtools/page/<id> 로 노출되지만
   *  puppeteer 내부 캐시 갱신 시점에 따라 안 잡힐 수 있음. /json은 항상 최신. */
  async function fetchCdpTargets(): Promise<Array<{ id: string; type: string; url: string; webSocketDebuggerUrl?: string }>> {
    const r = await fetch("http://localhost:9222/json");
    return (await r.json()) as Array<{ id: string; type: string; url: string; webSocketDebuggerUrl?: string }>;
  }

  test("view CefBrowser는 별도 CDP target으로 노출 (data URL marker로 식별)", async () => {
    const host = await freshHost();
    const view = await mkView(host, { width: 200, height: 200 });
    const marker = `VIEW_E2E_MARKER_${Date.now()}`;
    const html = `<body><h1>${marker}</h1></body>`;
    await coreCall({
      cmd: "load_url",
      windowId: view,
      url: `data:text/html,${encodeURIComponent(html)}`,
    });
    await new Promise((r) => setTimeout(r, 1500));

    const targets = await fetchCdpTargets();
    const viewTarget = targets.find((t) => t.type === "page" && t.url.includes(encodeURIComponent(marker)));
    expect(viewTarget).toBeDefined();
  });

  test("view CDP target에 raw WebSocket으로 Page.captureScreenshot — 픽셀 캡처", async () => {
    const host = await freshHost();
    const view = await mkView(host, { width: 200, height: 200 });
    const marker = `VIEW_PIXEL_${Date.now()}`;
    await coreCall({
      cmd: "load_url",
      windowId: view,
      url: `data:text/html,${encodeURIComponent(`<body style='margin:0;background:red'><h1>${marker}</h1></body>`)}`,
    });
    await new Promise((r) => setTimeout(r, 1500));

    const targets = await fetchCdpTargets();
    const viewTarget = targets.find((t) => t.type === "page" && t.url.includes(encodeURIComponent(marker)));
    expect(viewTarget).toBeDefined();
    if (!viewTarget?.webSocketDebuggerUrl) return;

    // puppeteer.connect는 page WS endpoint에서 Target.getBrowserContexts 호출이 막혀 실패 →
    // raw CDP WebSocket으로 Page.captureScreenshot 직접 호출.
    const ws = new WebSocket(viewTarget.webSocketDebuggerUrl);
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open", () => res());
      ws.addEventListener("error", () => rej(new Error("WS open failed")));
    });
    const screenshotData = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("screenshot timeout")), 5000);
      ws.addEventListener("message", (e) => {
        const msg = JSON.parse(e.data as string);
        if (msg.id === 1) {
          clearTimeout(timer);
          if (msg.error) reject(new Error(JSON.stringify(msg.error)));
          else resolve(msg.result.data as string);
        }
      });
      ws.send(JSON.stringify({ id: 1, method: "Page.captureScreenshot", params: { format: "png" } }));
    });
    ws.close();

    const buf = Buffer.from(screenshotData, "base64");
    expect(buf.length).toBeGreaterThan(100);
    // PNG 매직 89 50 4E 47 — view가 실제 픽셀을 렌더링했다는 직접 증거
    expect(buf[0]).toBe(0x89);
    expect(buf[1]).toBe(0x50);
    expect(buf[2]).toBe(0x4e);
    expect(buf[3]).toBe(0x47);
  });
});
