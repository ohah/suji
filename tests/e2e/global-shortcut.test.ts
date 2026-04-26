/**
 * Global shortcut E2E — `global_shortcut_*` core commands.
 *
 * 실행:
 *   ./tests/e2e/run-global-shortcut.sh
 *
 * 주의: 실제 키 입력 시뮬레이션은 시스템 권한 한계 + CI 환경에서 비결정적이라
 * 다루지 않는다. 등록/해제/조회의 wire-format 동작만 검증.
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

  // 사전 정리 — 테스트 간 leak 방지.
  await core({ cmd: "global_shortcut_unregister_all" });
});

afterAll(async () => {
  await core({ cmd: "global_shortcut_unregister_all" });
  await browser?.disconnect();
});

describe("global shortcut core commands", () => {
  test("register / isRegistered / unregister round-trip", async () => {
    const accel = "Cmd+Shift+F8";

    const r1 = await core<{ success: boolean }>({
      cmd: "global_shortcut_register",
      accelerator: accel,
      click: "test1",
    });
    expect(r1.success).toBe(true);

    const r2 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: accel,
    });
    expect(r2.registered).toBe(true);

    const r3 = await core<{ success: boolean }>({
      cmd: "global_shortcut_unregister",
      accelerator: accel,
    });
    expect(r3.success).toBe(true);

    const r4 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: accel,
    });
    expect(r4.registered).toBe(false);
  });

  test("duplicate register fails (already registered)", async () => {
    const accel = "Cmd+Shift+F9";
    const r1 = await core<{ success: boolean }>({
      cmd: "global_shortcut_register",
      accelerator: accel,
      click: "dup1",
    });
    expect(r1.success).toBe(true);

    const r2 = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: accel,
      click: "dup2",
    });
    expect(r2.success).toBe(false);
    expect(r2.error).toBe("register");

    await core({ cmd: "global_shortcut_unregister", accelerator: accel });
  });

  test("invalid accelerator returns error", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: "NotARealKey+Shift",
      click: "bad",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("register");
  });

  test("empty accelerator is rejected at handler level", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "global_shortcut_register",
      accelerator: "",
      click: "empty",
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("accelerator");
  });

  test("unregister on missing accelerator returns success:false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "global_shortcut_unregister",
      accelerator: "Cmd+Shift+F11",
    });
    expect(r.success).toBe(false);
  });

  test("unregisterAll clears all", async () => {
    await core({ cmd: "global_shortcut_register", accelerator: "Cmd+Shift+F10", click: "a" });
    await core({ cmd: "global_shortcut_register", accelerator: "Cmd+Shift+F12", click: "b" });

    const all = await core<{ success: boolean }>({ cmd: "global_shortcut_unregister_all" });
    expect(all.success).toBe(true);

    const c1 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: "Cmd+Shift+F10",
    });
    expect(c1.registered).toBe(false);
    const c2 = await core<{ registered: boolean }>({
      cmd: "global_shortcut_is_registered",
      accelerator: "Cmd+Shift+F12",
    });
    expect(c2.registered).toBe(false);
  });
});
