/**
 * Menu E2E — `suji.menu.{setApplicationMenu,resetApplicationMenu,popup}` 검증.
 *
 * 자동화 범위:
 *   - IPC wiring + success 응답
 *   - submenu/item/checkbox/separator 조합
 *   - resetApplicationMenu 기본 메뉴 복원
 *   - 잘못된 items 타입 parse error
 *   - Linux: GTK context menu popup 정상 응답
 *   - RUN_DESTRUCTIVE: osascript로 메뉴 항목 클릭 → `menu:click` 이벤트 수신
 *
 * 실행:
 *   ./tests/e2e/run-menu.sh
 *   RUN_DESTRUCTIVE=1 ./tests/e2e/run-menu.sh   # Accessibility 권한 필요
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

const runDestructive = process.env.RUN_DESTRUCTIVE === "1";
const isDarwin = process.platform === "darwin";
const isLinux = process.platform === "linux";

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
  try {
    await core({ cmd: "menu_reset_application_menu" });
  } catch {}
  await browser?.disconnect();
});

describe("menu_set_application_menu — wiring + 응답", () => {
  test.skipIf(!isDarwin)("submenu/item/checkbox/separator 조합", async () => {
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

  test.skipIf(!isDarwin)("id + visible:false 항목 — 파싱/네이티브 적용 무crash(success)", async () => {
    // id 는 UI 효과 없음(라운드트립), visible:false 는 NSMenuItem.setHidden:. 네이티브가
    // 새 필드로 거부/crash 하지 않고 success:true 면 통과(네이티브 메뉴는 DOM 부재라
    // 가시 상태는 단언 불가 — enabled 와 동일 관측 경계).
    const r = await core<{ success: boolean }>({
      cmd: "menu_set_application_menu",
      items: [
        {
          type: "submenu",
          label: "Tools",
          id: "tools-menu",
          submenu: [
            { label: "Hidden Item", click: "hidden", id: "hidden-item", visible: false },
            { label: "Shown Item", click: "shown", visible: true },
            { type: "checkbox", label: "Hidden Check", click: "hc", checked: true, visible: false },
          ],
        },
      ],
    });
    expect(r.success).toBe(true);
  });

  test.skipIf(!isDarwin)("Unicode 라벨 + click", async () => {
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

  test.skipIf(!isDarwin)("resetApplicationMenu 정상", async () => {
    const r = await core<{ success: boolean }>({ cmd: "menu_reset_application_menu" });
    expect(r.success).toBe(true);
  });

  test.skipIf(isDarwin)("application menu stub graceful false", async () => {
    const set = await core<{ success: boolean }>({
      cmd: "menu_set_application_menu",
      items: [{ label: "Tools", submenu: [{ label: "Run", click: "run" }] }],
    });
    expect(set.success).toBe(false);

    const reset = await core<{ success: boolean }>({ cmd: "menu_reset_application_menu" });
    expect(reset.success).toBe(false);
  });
});

describe("error / platform 분기", () => {
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

  // menu_popup: 정상 호출은 NSMenu 동기 모달이라 e2e 자동 클릭/dismiss
  // 불가(데스크톱 dialog 와 동일 경계 — 빌드+단위+menu:click 경로 재사용
  // 입증). parse 실패는 모달 전 즉시 반환이라 자동 검증 가능.
  test("menu_popup items non-array → parse error (모달 전)", async () => {
    const r = await core<{ success: boolean; error?: string }>({
      cmd: "menu_popup",
      items: "not-array" as any,
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("parse");
  });

  test.skipIf(!isLinux)("menu_popup 정상 응답 (Linux GTK)", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "menu_popup",
      x: 16,
      y: 16,
      items: [
        { label: "Linux Popup Item", click: "linux-popup-item" },
        { type: "checkbox", label: "Linux Popup Check", click: "linux-popup-check", checked: true },
        { type: "separator" },
        { type: "submenu", label: "Nested", submenu: [{ label: "Child", click: "linux-popup-child" }] },
      ],
    });
    expect(r.success).toBe(true);
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
