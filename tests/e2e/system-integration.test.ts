/**
 * 시스템 통합 e2e — screen.getAllDisplays / dock badge / powerSaveBlocker / safeStorage /
 * requestUserAttention.
 *
 * 실행: ./tests/e2e/run-system-integration.sh
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
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("screen.getAllDisplays", () => {
  test("최소 1개 display 반환 + 필수 필드", async () => {
    const r = await core<{ displays: any[] }>({ cmd: "screen_get_all_displays" });
    expect(Array.isArray(r.displays)).toBe(true);
    expect(r.displays.length).toBeGreaterThan(0);

    const d = r.displays[0];
    for (const k of ["index", "isPrimary", "x", "y", "width", "height",
                     "visibleX", "visibleY", "visibleWidth", "visibleHeight", "scaleFactor"]) {
      expect(d).toHaveProperty(k);
    }
    expect(d.width).toBeGreaterThan(0);
    expect(d.height).toBeGreaterThan(0);
    expect(d.scaleFactor).toBeGreaterThan(0);
  });

  test("primary display는 정확히 1개", async () => {
    const r = await core<{ displays: any[] }>({ cmd: "screen_get_all_displays" });
    const primary = r.displays.filter((d) => d.isPrimary);
    expect(primary.length).toBe(1);
  });

  test("visibleHeight ≤ height (메뉴바/dock 제외 영역)", async () => {
    const r = await core<{ displays: any[] }>({ cmd: "screen_get_all_displays" });
    for (const d of r.displays) {
      expect(d.visibleHeight).toBeLessThanOrEqual(d.height);
      expect(d.visibleWidth).toBeLessThanOrEqual(d.width);
    }
  });
});

describe("app.dock.setBadge", () => {
  test("set → get round-trip", async () => {
    await core({ cmd: "dock_set_badge", text: "42" });
    const r = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(r.text).toBe("42");
  });

  test("빈 문자열로 badge 제거", async () => {
    await core({ cmd: "dock_set_badge", text: "X" });
    await core({ cmd: "dock_set_badge", text: "" });
    const r = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(r.text).toBe("");
  });

  test("escape 안전 — 따옴표 포함 텍스트 round-trip", async () => {
    await core({ cmd: "dock_set_badge", text: 'a"b' });
    const r = await core<{ text: string }>({ cmd: "dock_get_badge" });
    expect(r.text).toBe('a"b');
    await core({ cmd: "dock_set_badge", text: "" });
  });
});

describe("powerSaveBlocker", () => {
  test("start → stop round-trip — display sleep 차단", async () => {
    const start = await core<{ id: number }>({
      cmd: "power_save_blocker_start",
      type: "prevent_display_sleep",
    });
    expect(start.id).toBeGreaterThan(0);

    const stop = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: start.id,
    });
    expect(stop.success).toBe(true);
  });

  test("app suspension 차단 type", async () => {
    const start = await core<{ id: number }>({
      cmd: "power_save_blocker_start",
      type: "prevent_app_suspension",
    });
    expect(start.id).toBeGreaterThan(0);
    await core({ cmd: "power_save_blocker_stop", id: start.id });
  });

  test("invalid id (0) stop은 false", async () => {
    const stop = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: 0,
    });
    expect(stop.success).toBe(false);
  });

  test("이미 stop된 id 두 번째 stop은 false (idempotent guard)", async () => {
    const start = await core<{ id: number }>({
      cmd: "power_save_blocker_start",
      type: "prevent_display_sleep",
    });
    const stop1 = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: start.id,
    });
    expect(stop1.success).toBe(true);
    const stop2 = await core<{ success: boolean }>({
      cmd: "power_save_blocker_stop",
      id: start.id,
    });
    expect(stop2.success).toBe(false);
  });
});

describe("safeStorage (Keychain)", () => {
  const SVC = "Suji-e2e-test";

  test("set → get round-trip", async () => {
    const account = `acc-${Date.now()}-1`;
    const setR = await core<{ success: boolean }>({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "secret-value",
    });
    expect(setR.success).toBe(true);

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe("secret-value");

    await core({ cmd: "safe_storage_delete", service: SVC, account });
  });

  test("delete 후 get은 빈 문자열", async () => {
    const account = `acc-${Date.now()}-2`;
    await core({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "to-delete",
    });
    const del = await core<{ success: boolean }>({
      cmd: "safe_storage_delete",
      service: SVC,
      account,
    });
    expect(del.success).toBe(true);

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe("");
  });

  test("같은 key set 두 번 — 두번째 값으로 update (idempotent)", async () => {
    const account = `acc-${Date.now()}-3`;
    await core({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "first",
    });
    await core({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value: "second",
    });

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe("second");

    await core({ cmd: "safe_storage_delete", service: SVC, account });
  });

  test("escape — 따옴표/백슬래시 포함 value round-trip", async () => {
    const account = `acc-${Date.now()}-4`;
    const value = 'a"b\\c';
    const setR = await core<{ success: boolean }>({
      cmd: "safe_storage_set",
      service: SVC,
      account,
      value,
    });
    expect(setR.success).toBe(true);

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account,
    });
    expect(getR.value).toBe(value);

    await core({ cmd: "safe_storage_delete", service: SVC, account });
  });
});

describe("app.requestUserAttention (dock bounce)", () => {
  // NSApp 문서: 호출 시점에 앱이 active면 0 반환 (no-op). e2e는 puppeteer가
  // attach된 active app이라 0이 자주 발생 — id 0 응답을 정상 신호로 처리.

  test("critical request → id ≥ 0 + 발급된 id로 cancel 성공", async () => {
    const r = await core<{ id: number }>({
      cmd: "app_attention_request",
      critical: true,
    });
    expect(r.id).toBeGreaterThanOrEqual(0);
    if (r.id > 0) {
      const c = await core<{ success: boolean }>({
        cmd: "app_attention_cancel",
        id: r.id,
      });
      expect(c.success).toBe(true);
    }
  });

  test("informational request도 id ≥ 0", async () => {
    const r = await core<{ id: number }>({
      cmd: "app_attention_request",
      critical: false,
    });
    expect(r.id).toBeGreaterThanOrEqual(0);
    if (r.id > 0) {
      await core({ cmd: "app_attention_cancel", id: r.id });
    }
  });

  test("invalid id (0) cancel은 false (guard)", async () => {
    const c = await core<{ success: boolean }>({
      cmd: "app_attention_cancel",
      id: 0,
    });
    expect(c.success).toBe(false);
  });

  test("nonzero id cancel은 항상 true (NSApp API가 void)", async () => {
    // request_id를 발급받지 못한 임의의 nonzero id로 cancel — NSApp이 void로 반환하므로
    // 우리 wrapper는 id != 0이면 무조건 true. 이 비대칭은 의도된 contract.
    const c = await core<{ success: boolean }>({
      cmd: "app_attention_cancel",
      id: 999999,
    });
    expect(c.success).toBe(true);
  });
});
