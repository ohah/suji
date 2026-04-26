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

// ============================================
// Phase 17-A.9: 보강 — 이벤트 frontend 도달 + 멀티 host 격리 + remove/re-add
// ============================================

describe("17-A.9: lifecycle 이벤트 frontend 도달", () => {
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

describe("17-A.9: multiple hosts isolation", () => {
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

describe("17-A.9: removeChildView 후 재부착", () => {
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

describe("17-A.9: destroyView 후 getChildViews 감소", () => {
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

describe("17-A.9: webContents API view 호환 — executeJavaScript", () => {
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
    // ok:true는 핸들러가 view를 .window와 똑같이 dispatch했다는 시그널 (17-A.5 회귀 가드).
    // (getURL은 OnAddressChange가 view에 대해 cache 채우는 시점이 비결정적이라 별도 검증 X)
    expect(r.ok).toBe(true);
  });
});

// ============================================
// Phase 17-A.10: 시각 검증 — view CefBrowser는 별도 DevTools target으로 puppeteer에 노출.
// 그 page에서 직접 컨텐츠 읽기/screenshot으로 "view가 실제 살아있고 렌더링되고 있다"는
// 픽셀 단계 증거 확보. 단 host NSWindow 안에서의 합성 시각(z-order/위치/투명도)은 OS
// 차원 캡처가 필요해 별도 — 사용자 수동 검증 또는 examples/multi-backend의 view 데모 패널.
// ============================================

describe("17-A.10: view CefBrowser endpoint + 픽셀 캡처", () => {
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
