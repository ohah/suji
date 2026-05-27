/**
 * Tray E2E — `suji.tray.{create,setTitle,setTooltip,setMenu,destroy}` 검증.
 *
 * NSStatusItem / GTK StatusIcon / Windows tray popup은 puppeteer로 직접 클릭하기 어렵다. 자동화 범위:
 *   - IPC wiring + 응답 shape (trayId / success boolean)
 *   - 다중 tray (여러 개 동시 생성 → 다른 trayId)
 *   - destroy → 같은 id 재호출 false (graceful)
 *   - setMenu 잘못된 trayId → false
 *   - menu items separator + 일반 항목 혼합
 *   - RUN_DESTRUCTIVE(macOS): osascript로 메뉴 항목 클릭 트리거 → `tray:menu-click` 이벤트 수신
 *
 * 실행:
 *   ./tests/e2e/run-tray.sh
 *   RUN_DESTRUCTIVE=1 ./tests/e2e/run-tray.sh   # osascript 메뉴 클릭 (Accessibility 권한 필요)
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;
const createdTrayIds: number[] = [];

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

const runDestructive = process.env.RUN_DESTRUCTIVE === "1";

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
});

afterAll(async () => {
  // Cleanup all trays created during tests
  for (const id of createdTrayIds) {
    try {
      await core({ cmd: "tray_destroy", trayId: id });
    } catch {}
  }
  await browser?.disconnect();
});

// ============================================
// Wiring + 응답 shape
// ============================================

describe("tray.create — wiring + 응답", () => {
  test("title + tooltip 둘 다 → trayId > 0", async () => {
    const r = await core<{ trayId: number }>({ cmd: "tray_create", title: "🚀 Test", tooltip: "tooltip" });
    expect(r.trayId).toBeGreaterThan(0);
    createdTrayIds.push(r.trayId);
  });

  test("title만 → trayId > 0", async () => {
    const r = await core<{ trayId: number }>({ cmd: "tray_create", title: "Only Title" });
    expect(r.trayId).toBeGreaterThan(0);
    createdTrayIds.push(r.trayId);
  });

  test("빈 옵션 → trayId 여전히 > 0 (native tray object 자체는 생성)", async () => {
    const r = await core<{ trayId: number }>({ cmd: "tray_create" });
    expect(r.trayId).toBeGreaterThan(0);
    createdTrayIds.push(r.trayId);
  });
});

describe("다중 tray", () => {
  test("3개 동시 생성 — 각자 다른 trayId", async () => {
    const ids: number[] = [];
    for (let i = 0; i < 3; i++) {
      const r = await core<{ trayId: number }>({ cmd: "tray_create", title: `T${i}` });
      expect(r.trayId).toBeGreaterThan(0);
      ids.push(r.trayId);
      createdTrayIds.push(r.trayId);
    }
    // 모두 unique
    expect(new Set(ids).size).toBe(3);
  });
});

describe("setTitle / setTooltip / setMenu — 응답", () => {
  let trayId: number;
  beforeAll(async () => {
    const r = await core<{ trayId: number }>({ cmd: "tray_create", title: "🎯 Mutate Test" });
    trayId = r.trayId;
    createdTrayIds.push(trayId);
  });

  test("setTitle 정상", async () => {
    const r = await core<{ success: boolean }>({ cmd: "tray_set_title", trayId, title: "🎯 Updated" });
    expect(r.success).toBe(true);
  });

  test("setTitle Unicode/이모지/줄바꿈 보존", async () => {
    const r = await core<{ success: boolean }>({ cmd: "tray_set_title", trayId, title: "한글 🚀\nNewLine" });
    expect(r.success).toBe(true);
  });

  test("setTooltip 정상", async () => {
    const r = await core<{ success: boolean }>({ cmd: "tray_set_tooltip", trayId, tooltip: "Updated tip" });
    expect(r.success).toBe(true);
  });

  test("setMenu separator + 일반 항목 혼합", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "tray_set_menu", trayId,
      items: [
        { label: "Show", click: "show-main" },
        { label: "Reload", click: "reload" },
        { type: "separator" },
        { label: "Quit", click: "quit-app" },
      ],
    });
    expect(r.success).toBe(true);
  });

  test("setMenu 빈 배열 (메뉴 비움)", async () => {
    const r = await core<{ success: boolean }>({ cmd: "tray_set_menu", trayId, items: [] });
    expect(r.success).toBe(true);
  });

  test("setMenu 다시 호출 (replace) → 정상", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "tray_set_menu", trayId,
      items: [{ label: "New only", click: "new" }],
    });
    expect(r.success).toBe(true);
  });

  test("Unicode 메뉴 라벨 + click", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "tray_set_menu", trayId,
      items: [
        { label: "한글 항목 🎉", click: "korean-event" },
        { label: 'with "quotes" \\backslash', click: 'event-with-special' },
      ],
    });
    expect(r.success).toBe(true);
  });
});

// ============================================
// Error 분기 — graceful
// ============================================

describe("error 분기", () => {
  test("setTitle 잘못된 trayId → success: false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "tray_set_title", trayId: 99999, title: "X" });
    expect(r.success).toBe(false);
  });

  test("setTooltip 잘못된 trayId → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "tray_set_tooltip", trayId: 99999, tooltip: "X" });
    expect(r.success).toBe(false);
  });

  test("setMenu 잘못된 trayId → false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "tray_set_menu", trayId: 99999,
      items: [{ label: "X", click: "x" }],
    });
    expect(r.success).toBe(false);
  });

  test("destroy 잘못된 trayId → false", async () => {
    const r = await core<{ success: boolean }>({ cmd: "tray_destroy", trayId: 99999 });
    expect(r.success).toBe(false);
  });

  test("destroy 후 같은 id 재호출 → false (idempotent fail)", async () => {
    const c = await core<{ trayId: number }>({ cmd: "tray_create", title: "Destroy test" });
    const id = c.trayId;
    expect(id).toBeGreaterThan(0);

    const d1 = await core<{ success: boolean }>({ cmd: "tray_destroy", trayId: id });
    expect(d1.success).toBe(true);

    const d2 = await core<{ success: boolean }>({ cmd: "tray_destroy", trayId: id });
    expect(d2.success).toBe(false);
  });

  test("setMenu items 잘못된 type (non-array) → graceful (parse error)", async () => {
    const r = await core<{ success: boolean; error?: string }>({
      cmd: "tray_set_menu", trayId: 1, items: "not-array" as any,
    });
    expect(r.success).toBe(false);
  });
});

// ============================================
// click 이벤트 — RUN_DESTRUCTIVE (osascript로 메뉴 클릭 트리거)
// ============================================

describe("click 이벤트 라우팅 — RUN_DESTRUCTIVE", () => {
  test.skipIf(!runDestructive)(
    "메뉴 항목 클릭 시 tray:menu-click {trayId, click} 이벤트 수신",
    async () => {
      const c = await core<{ trayId: number }>({ cmd: "tray_create", title: "🎯 ClickTest" });
      const trayId = c.trayId;
      createdTrayIds.push(trayId);

      await core({
        cmd: "tray_set_menu", trayId,
        items: [{ label: "ClickItem", click: "test-click-event" }],
      });

      // page에서 이벤트 listener 설치
      await page.evaluate(() => {
        (window as any).__tray_click__ = null;
        (window as any).__suji__.on('tray:menu-click', (data: any) => {
          (window as any).__tray_click__ = data;
        });
      });

      // osascript로 트레이 메뉴 항목 클릭 — System Events로 메뉴바 status item 접근.
      // process "suji"의 menu bar items 중 마지막(=우리가 만든) → click → click "ClickItem".
      const proc = Bun.spawn([
        "osascript", "-e",
        `tell application "System Events" to tell process "suji" to tell menu bar 2 to click menu item "ClickItem" of menu 1 of menu bar item 1`,
      ]);
      await proc.exited;

      // 이벤트 수신 폴링 (최대 5초)
      let received: any = null;
      for (let i = 0; i < 50; i++) {
        received = await page.evaluate(() => (window as any).__tray_click__);
        if (received) break;
        await new Promise(r => setTimeout(r, 100));
      }

      expect(received).not.toBeNull();
      expect(received.trayId).toBe(trayId);
      expect(received.click).toBe("test-click-event");
    },
    20000,
  );
});
