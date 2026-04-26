/**
 * Phase 5-C Notification E2E — `suji.notification.{isSupported, requestPermission, show, close}`.
 *
 * 주의: UNUserNotificationCenter는 valid Bundle ID 필요. `suji dev` loose binary는 Bundle ID
 * 없어 isSupported()가 false 반환 (notification.m이 Bundle ID 검사 후 stub). 이 E2E는
 * "stub 동작" + IPC 응답 형식 + 라우팅을 검증. 실제 알림 표시는 `.app` 번들 후 manual.
 *
 * 실행: tests/e2e/run-notification.sh
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
  await browser?.disconnect();
});

describe("notification.isSupported — Bundle ID 검사", () => {
  test("응답 형식 — supported boolean", async () => {
    const r = await core<{ supported: boolean }>({ cmd: "notification_is_supported" });
    expect(typeof r.supported).toBe("boolean");
    // suji dev (loose binary) 환경에선 Bundle ID 없어 false. .app 번들이면 true.
  });
});

describe("notification.show — IPC 라우팅", () => {
  test("응답 형식 — notificationId + success", async () => {
    const r = await core<{ notificationId: string; success: boolean }>({
      cmd: "notification_show",
      title: "Test",
      body: "Hello",
      silent: false,
    });
    expect(typeof r.notificationId).toBe("string");
    expect(r.notificationId).toMatch(/^suji-notif-\d+$/);
    expect(typeof r.success).toBe("boolean");
  });

  test("notificationId — 매 호출마다 증가 (unique)", async () => {
    const ids = new Set<string>();
    for (let i = 0; i < 5; i++) {
      const r = await core<{ notificationId: string }>({
        cmd: "notification_show", title: `T${i}`, body: "B",
      });
      ids.add(r.notificationId);
    }
    expect(ids.size).toBe(5);
  });

  test("title/body Unicode + escape 보존", async () => {
    const r = await core<{ notificationId: string }>({
      cmd: "notification_show",
      title: "🎉 안녕",
      body: 'Line 1\nLine 2 with "quotes" \\backslash',
      silent: true,
    });
    expect(r.notificationId).toMatch(/^suji-notif-/);
  });

  test("silent=true 옵션", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "notification_show", title: "Silent", body: "no sound", silent: true,
    });
    expect(typeof r.success).toBe("boolean");
  });

  test("title/body 빈 문자열도 graceful", async () => {
    const r = await core<{ notificationId: string }>({
      cmd: "notification_show", title: "", body: "",
    });
    expect(r.notificationId).toMatch(/^suji-notif-/);
  });
});

describe("notification.close", () => {
  test("close 후 응답 형식 — success boolean", async () => {
    const c = await core<{ notificationId: string }>({
      cmd: "notification_show", title: "Close test", body: "...",
    });
    const r = await core<{ success: boolean }>({
      cmd: "notification_close", notificationId: c.notificationId,
    });
    expect(typeof r.success).toBe("boolean");
  });

  test("잘못된 notificationId — graceful", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "notification_close", notificationId: "non-existent-id",
    });
    expect(typeof r.success).toBe("boolean");
  });
});

describe("notification.requestPermission — IPC 라우팅", () => {
  test("응답 형식 — granted boolean", async () => {
    // 첫 호출 시 OS 다이얼로그 가능 — Bundle ID 없으면 즉시 false 반환.
    const r = await core<{ granted: boolean }>({ cmd: "notification_request_permission" });
    expect(typeof r.granted).toBe("boolean");
  });
});
