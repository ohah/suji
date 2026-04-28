/**
 * Window lifecycle event E2E — resize/focus/blur/move 이벤트가 실제로 emit되는지.
 *
 * 실행:
 *   ./tests/e2e/run-window-lifecycle-events.sh
 *
 * 전략: 기존 창 1개 + 새 창 1개를 만들고 setBounds/show/hide 등 OS 호출로
 * 이벤트를 트리거 후, frontend의 `suji.on(...)`이 받은 payload를 검증.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

// 한 채널의 모든 이벤트를 수집하는 helper. timeoutMs 동안 또는 maxCount 도달까지.
async function collect<T = any>(channel: string, timeoutMs: number, maxCount = 100): Promise<T[]> {
  return page.evaluate(
    async ({ channel, timeoutMs, maxCount }: { channel: string; timeoutMs: number; maxCount: number }) => {
      const events: any[] = [];
      const off = (window as any).__suji__.on(channel, (payload: string) => {
        try {
          events.push(JSON.parse(payload));
        } catch {
          events.push(payload);
        }
        if (events.length >= maxCount) off();
      });
      await new Promise((resolve) => setTimeout(resolve, timeoutMs));
      off();
      return events;
    },
    { channel, timeoutMs, maxCount },
  );
}

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  page = pages[0];
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("window lifecycle events", () => {
  test("setBounds triggers window:resized", async () => {
    // 첫 창 ID는 항상 1 (suji.json startup window).
    // moved는 macOS setFrame:display:가 origin 변경에 windowDidMove를 비결정적으로
    // 발화 (CI runner와 로컬이 다름) → 인프라 검증은 다른 test로 위임.
    const collector = collect<{ windowId: number; x?: number; y?: number; width?: number; height?: number }>(
      "window:resized",
      1500,
    );

    await core({ cmd: "set_bounds", windowId: 1, x: 200, y: 200, width: 800, height: 600 });
    await new Promise((r) => setTimeout(r, 300));
    await core({ cmd: "set_bounds", windowId: 1, x: 250, y: 250, width: 850, height: 650 });

    const resized = await collector;
    expect(resized.length).toBeGreaterThan(0);
    expect(resized[resized.length - 1].windowId).toBe(1);
    expect(resized[resized.length - 1].width).toBeGreaterThan(0);
    expect(resized[resized.length - 1].height).toBeGreaterThan(0);
  });

  test("새 창 생성 후 setBounds → 새 창에서도 resized 발화", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "lifecycle-second",
      x: 400, y: 400, width: 400, height: 300,
    });
    expect(typeof created.windowId).toBe("number");
    const newId = created.windowId;

    const resizeCol = collect<{ windowId: number; width: number; height: number }>(
      "window:resized",
      1500,
    );
    await core({ cmd: "set_bounds", windowId: newId, x: 450, y: 450, width: 500, height: 400 });

    const resized = await resizeCol;
    const newWindowEvents = resized.filter((e) => e.windowId === newId);
    expect(newWindowEvents.length).toBeGreaterThan(0);
    expect(newWindowEvents[newWindowEvents.length - 1].width).toBe(500);
    expect(newWindowEvents[newWindowEvents.length - 1].height).toBe(400);

    await core({ cmd: "destroy_window", windowId: newId });
    await new Promise((r) => setTimeout(r, 200));
  });

  // focus/blur는 macOS app activation에 의존 (다른 앱이 활성 중이면 key window 안 됨).
  // e2e에서 비결정적이라 인프라만 unit test (window_manager_test)로 검증.
  test.skip("focus/blur는 e2e에서 비결정적 — 인프라는 unit test 회귀로 검증", () => {});

  test("change-detection guard — 동일 setBounds 두 번이면 resized 한 번만", async () => {
    // 우선 다른 bounds로 한번 → 이후 동일 bounds 두 번 호출.
    await core({ cmd: "set_bounds", windowId: 1, x: 100, y: 100, width: 700, height: 500 });
    await new Promise((r) => setTimeout(r, 200));

    const collector = collect<{ windowId: number; width: number; height: number }>(
      "window:resized",
      1500,
    );

    // 동일 bounds — 첫 호출은 새 dimension이라 emit, 두 번째는 동일이라 dedupe.
    await core({ cmd: "set_bounds", windowId: 1, x: 200, y: 200, width: 800, height: 600 });
    await new Promise((r) => setTimeout(r, 200));
    await core({ cmd: "set_bounds", windowId: 1, x: 200, y: 200, width: 800, height: 600 });
    await new Promise((r) => setTimeout(r, 200));
    await core({ cmd: "set_bounds", windowId: 1, x: 200, y: 200, width: 800, height: 600 });

    const events = await collector;
    const win1Events = events.filter((e) => e.windowId === 1 && e.width === 800 && e.height === 600);
    // 동일 (200,200,800,600) 3회 호출했지만 cache로 1번만 emit.
    expect(win1Events.length).toBe(1);
  });

  test("4 typed callback 분리 — resized payload는 5필드, moved/focus/blur 미포함", async () => {
    // 4 typed callback 분리 효과를 emit payload shape으로 검증:
    //   resized → {windowId, x, y, width, height}
    //   moved   → {windowId, x, y}        (width/height 없음)
    //   focus   → {windowId}              (좌표 전혀 없음)
    //   blur    → {windowId}              (좌표 전혀 없음)
    // setFrame은 macOS에서 origin-only 변경에 windowDidMove 비결정적이라
    // resized payload shape만 신뢰 가능.
    const collector = collect<Record<string, unknown>>("window:resized", 1500);
    await core({ cmd: "set_bounds", windowId: 1, x: 300, y: 300, width: 900, height: 700 });

    const events = await collector;
    expect(events.length).toBeGreaterThan(0);
    const ev = events[events.length - 1];
    expect(ev).toHaveProperty("windowId");
    expect(ev).toHaveProperty("x");
    expect(ev).toHaveProperty("y");
    expect(ev).toHaveProperty("width");
    expect(ev).toHaveProperty("height");
  });

  test("destroy 후 더 이상 이벤트 발화 안 됨", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "destroy-test",
      x: 500, y: 500, width: 300, height: 200,
    });
    const id = created.windowId;
    await core({ cmd: "destroy_window", windowId: id });
    await new Promise((r) => setTimeout(r, 300));

    // destroyed 이후 어떤 이벤트도 이 windowId로 오면 안 됨
    const allChannels = ["window:resized", "window:focus", "window:blur", "window:moved"] as const;
    for (const ch of allChannels) {
      const evs = await collect<{ windowId: number }>(ch, 500);
      expect(evs.every((e) => e.windowId !== id)).toBe(true);
    }
  });

  // ==================== Phase 5: minimize/maximize/fullscreen ====================
  // 새 창을 만들고 IPC로 NSWindow를 조작 → NSWindowDelegate가 이벤트 발화.
  // CI runner는 dock 동작이 비결정적이라 toBeGreaterThan(0)만 검증 (정확한 횟수 X).

  test("minimize → window:minimize 이벤트, restore_window → window:restore", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "lifecycle-minimize",
      x: 600, y: 300, width: 400, height: 300,
    });
    const id = created.windowId;
    await new Promise((r) => setTimeout(r, 200));

    const minCol = collect<{ windowId: number }>("window:minimize", 1500);
    await core({ cmd: "minimize", windowId: id });
    const minEvs = (await minCol).filter((e) => e.windowId === id);
    expect(minEvs.length).toBeGreaterThan(0);

    // IPC isMinimized로 상태 reflective 검증.
    const isMin = await core<{ minimized: boolean }>({ cmd: "is_minimized", windowId: id });
    expect(isMin.minimized).toBe(true);

    const restCol = collect<{ windowId: number }>("window:restore", 1500);
    await core({ cmd: "restore_window", windowId: id });
    const restEvs = (await restCol).filter((e) => e.windowId === id);
    expect(restEvs.length).toBeGreaterThan(0);

    await core({ cmd: "destroy_window", windowId: id });
    await new Promise((r) => setTimeout(r, 200));
  });

  test("maximize → window:maximize 이벤트, unmaximize → window:unmaximize", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "lifecycle-maximize",
      x: 100, y: 100, width: 400, height: 300,
    });
    const id = created.windowId;
    await new Promise((r) => setTimeout(r, 200));

    const maxCol = collect<{ windowId: number }>("window:maximize", 1500);
    await core({ cmd: "maximize", windowId: id });
    const maxEvs = (await maxCol).filter((e) => e.windowId === id);
    expect(maxEvs.length).toBeGreaterThan(0);

    const isMax = await core<{ maximized: boolean }>({ cmd: "is_maximized", windowId: id });
    expect(isMax.maximized).toBe(true);

    const unmaxCol = collect<{ windowId: number }>("window:unmaximize", 1500);
    await core({ cmd: "unmaximize", windowId: id });
    const unmaxEvs = (await unmaxCol).filter((e) => e.windowId === id);
    expect(unmaxEvs.length).toBeGreaterThan(0);

    await core({ cmd: "destroy_window", windowId: id });
    await new Promise((r) => setTimeout(r, 200));
  });

  test("set_fullscreen → enter-full-screen / leave-full-screen 이벤트", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "lifecycle-fullscreen",
      x: 200, y: 200, width: 400, height: 300,
    });
    const id = created.windowId;
    await new Promise((r) => setTimeout(r, 200));

    const enterCol = collect<{ windowId: number }>("window:enter-full-screen", 3000);
    await core({ cmd: "set_fullscreen", windowId: id, flag: true });
    // toggleFullScreen 애니메이션 ~1s
    const enterEvs = (await enterCol).filter((e) => e.windowId === id);
    expect(enterEvs.length).toBeGreaterThan(0);

    const isFs = await core<{ fullscreen: boolean }>({ cmd: "is_fullscreen", windowId: id });
    expect(isFs.fullscreen).toBe(true);

    const leaveCol = collect<{ windowId: number }>("window:leave-full-screen", 3000);
    await core({ cmd: "set_fullscreen", windowId: id, flag: false });
    const leaveEvs = (await leaveCol).filter((e) => e.windowId === id);
    expect(leaveEvs.length).toBeGreaterThan(0);

    await core({ cmd: "destroy_window", windowId: id });
    await new Promise((r) => setTimeout(r, 500));
  });

  test("set_fullscreen 멱등 — 같은 flag 두 번이면 두 번째는 이벤트 발화 안 함", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "lifecycle-fullscreen-idempotent",
      x: 200, y: 200, width: 400, height: 300,
    });
    const id = created.windowId;
    await new Promise((r) => setTimeout(r, 200));

    await core({ cmd: "set_fullscreen", windowId: id, flag: true });
    await new Promise((r) => setTimeout(r, 1500));

    // 이미 fullscreen인 상태에서 다시 true → toggle 미발생 → 이벤트 X.
    const enterCol = collect<{ windowId: number }>("window:enter-full-screen", 800);
    await core({ cmd: "set_fullscreen", windowId: id, flag: true });
    const enterEvs = (await enterCol).filter((e) => e.windowId === id);
    expect(enterEvs.length).toBe(0);

    await core({ cmd: "set_fullscreen", windowId: id, flag: false });
    await new Promise((r) => setTimeout(r, 1500));
    await core({ cmd: "destroy_window", windowId: id });
    await new Promise((r) => setTimeout(r, 200));
  });
});
