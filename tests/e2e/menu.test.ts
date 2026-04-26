/**
 * Menu E2E — `suji.menu.{setApplicationMenu,resetApplicationMenu}` 검증.
 *
 * 자동화 범위:
 *   - IPC wiring + success 응답
 *   - submenu/item/checkbox/separator 조합
 *   - resetApplicationMenu 기본 메뉴 복원
 *   - 잘못된 items 타입 parse error
 *   - RUN_DESTRUCTIVE: osascript로 메뉴 항목 클릭 → `menu:click` 이벤트 수신
 *
 * 실행:
 *   ./tests/e2e/run-menu.sh
 *   RUN_DESTRUCTIVE=1 ./tests/e2e/run-menu.sh   # Accessibility 권한 필요
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

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
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  page = pages[0];
  page.setDefaultTimeout(15000);
});

afterAll(async () => {
  try {
    await core({ cmd: "menu_reset_application_menu" });
  } catch {}
  await browser?.disconnect();
});

describe("menu_set_application_menu — wiring + 응답", () => {
  test("submenu/item/checkbox/separator 조합", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "menu_set_application_menu",
      items: [
        {
          type: "submenu",
          label: "Tools",
          submenu: [
            { label: "Run Task", click: "run-task" },
            { type: "checkbox", label: "Enabled Flag", click: "toggle-flag", checked: true },
            { type: "separator" },
            {
              type: "submenu",
              label: "Nested",
              submenu: [{ label: "Nested Item", click: "nested-item" }],
            },
          ],
        },
      ],
    });
    expect(r.success).toBe(true);
  });

  test("Unicode 라벨 + click", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "menu_set_application_menu",
      items: [
        {
          label: "도구",
          submenu: [
            { label: "실행 🚀", click: "run-korean" },
            { label: 'with "quotes" \\backslash', click: "special-click" },
          ],
        },
      ],
    });
    expect(r.success).toBe(true);
  });

  test("resetApplicationMenu 정상", async () => {
    const r = await core<{ success: boolean }>({ cmd: "menu_reset_application_menu" });
    expect(r.success).toBe(true);
  });
});

describe("error 분기", () => {
  test("items non-array → parse error", async () => {
    const r = await core<{ success: boolean; error?: string }>({
      cmd: "menu_set_application_menu",
      items: "not-array" as any,
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("parse");
  });

  test("submenu non-array → parse error", async () => {
    const r = await core<{ success: boolean; error?: string }>({
      cmd: "menu_set_application_menu",
      items: [{ type: "submenu", label: "Broken", submenu: "nope" as any }],
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("parse");
  });
});

describe("click 이벤트 라우팅 — RUN_DESTRUCTIVE", () => {
  test.skipIf(!runDestructive)(
    "메뉴 항목 클릭 시 menu:click {click} 이벤트 수신",
    async () => {
      const r = await core<{ success: boolean }>({
        cmd: "menu_set_application_menu",
        items: [
          {
            type: "submenu",
            label: "E2ETools",
            submenu: [
              { label: "ClickItem", click: "menu-click-event" },
              { type: "checkbox", label: "CheckItem", click: "menu-check-event", checked: false },
            ],
          },
        ],
      });
      expect(r.success).toBe(true);

      await page.evaluate(() => {
        (window as any).__menu_click__ = null;
        (window as any).__suji__.on("menu:click", (data: any) => {
          (window as any).__menu_click__ = data;
        });
      });

      const proc = Bun.spawn([
        "osascript",
        "-e",
        `tell application "System Events" to tell process "suji" to click menu item "ClickItem" of menu "E2ETools" of menu bar 1`,
      ]);
      await proc.exited;

      let received: any = null;
      for (let i = 0; i < 50; i++) {
        received = await page.evaluate(() => (window as any).__menu_click__);
        if (received) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }

      expect(received).not.toBeNull();
      expect(received.click).toBe("menu-click-event");
    },
    20000,
  );
});
