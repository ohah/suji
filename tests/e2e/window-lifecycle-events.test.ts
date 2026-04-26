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
});
