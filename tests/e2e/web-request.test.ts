/**
 * webRequest URL filter E2E — blocklist 등록 시 매칭 URL fetch가 cancel되고,
 * `webRequest:completed` 이벤트가 status code/error를 보고하는지 검증.
 *
 * 실행: ./tests/e2e/run-web-request.sh
 */
import { afterAll, beforeAll, afterEach, describe, expect, test } from "bun:test";
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
  page = (await browser.pages())[0];
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
});

afterEach(async () => {
  // 다음 테스트 격리 — blocklist 비움.
  await core({ cmd: "web_request_set_blocked_urls", patterns: [] });
});

describe("webRequest blocklist", () => {
  test("setBlockedUrls는 등록된 패턴 개수 반환", async () => {
    const r = await core<{ count: number }>({
      cmd: "web_request_set_blocked_urls",
      patterns: ["https://blocked.test/*", "https://*.ads/*"],
    });
    expect(r.count).toBe(2);
  });

  test("빈 list는 count=0", async () => {
    const r = await core<{ count: number }>({
      cmd: "web_request_set_blocked_urls",
      patterns: [],
    });
    expect(r.count).toBe(0);
  });

  test("blocklist 매칭되는 fetch는 차단됨 (TypeError 또는 status=0)", async () => {
    await core({
      cmd: "web_request_set_blocked_urls",
      patterns: ["https://blocked-test.suji.invalid/*"],
    });
    // page에서 fetch — 패턴 매칭이라 cancel됨 (TypeError).
    const result = await page.evaluate(async () => {
      try {
        const resp = await fetch("https://blocked-test.suji.invalid/api");
        return { ok: true, status: resp.status };
      } catch (e: any) {
        return { ok: false, error: String(e.message ?? e) };
      }
    });
    expect(result.ok).toBe(false);
  });

  test("blocklist 외 URL은 통과 (vite dev server self)", async () => {
    await core({
      cmd: "web_request_set_blocked_urls",
      patterns: ["https://blocked-only.suji.invalid/*"],
    });
    const result = await page.evaluate(async () => {
      try {
        // vite dev server는 페이지가 로드된 origin이라 통과해야.
        const resp = await fetch(window.location.origin + "/");
        return { ok: true, status: resp.status };
      } catch (e: any) {
        return { ok: false, error: String(e.message ?? e) };
      }
    });
    expect(result.ok).toBe(true);
  });

  test("webRequest:completed 이벤트 — status code 보고", async () => {
    // listener 먼저 등록.
    const listenerKey = await page.evaluate(() => {
      const events: any[] = [];
      const off = (window as any).__suji__.on(
        "webRequest:completed",
        (payload: string) => {
          try { events.push(JSON.parse(payload)); } catch { events.push(payload); }
        },
      );
      const reg = ((window as any).__wr_test__ ||= {});
      const k = String(Math.random());
      reg[k] = { events, off };
      return k;
    });

    // 페이지 self-fetch → completed 이벤트 도달.
    await page.evaluate(async () => {
      await fetch(window.location.origin + "/").catch(() => {});
    });

    const found = await page.evaluate(
      async ({ k }) => {
        const reg = (window as any).__wr_test__;
        const c = reg[k];
        const start = Date.now();
        while (Date.now() - start < 5000) {
          if (c.events.length > 0) {
            c.off();
            const evs = c.events.slice();
            delete reg[k];
            return evs;
          }
          await new Promise((r) => setTimeout(r, 100));
        }
        c.off();
        delete reg[k];
        return [];
      },
      { k: listenerKey },
    );
    expect(found.length).toBeGreaterThan(0);
    expect(found[0]).toHaveProperty("url");
    expect(found[0]).toHaveProperty("statusCode");
  });
});
