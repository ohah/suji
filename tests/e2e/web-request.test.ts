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

  test("blocked URL의 completed 이벤트 — statusCode=0 + requestStatus=CANCELED(3)", async () => {
    await core({
      cmd: "web_request_set_blocked_urls",
      patterns: ["https://blocked-completed.suji.invalid/*"],
    });
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

    await page.evaluate(async () => {
      await fetch("https://blocked-completed.suji.invalid/api").catch(() => {});
    });

    const blockedEvent = await page.evaluate(
      async ({ k }) => {
        const reg = (window as any).__wr_test__;
        const c = reg[k];
        const start = Date.now();
        while (Date.now() - start < 5000) {
          const found = c.events.find((e: any) =>
            typeof e.url === "string" && e.url.includes("blocked-completed.suji.invalid"),
          );
          if (found) {
            c.off();
            delete reg[k];
            return found;
          }
          await new Promise((r) => setTimeout(r, 100));
        }
        c.off();
        delete reg[k];
        return null;
      },
      { k: listenerKey },
    );
    expect(blockedEvent).not.toBeNull();
    expect(blockedEvent.statusCode).toBe(0);
    // CEF cef_urlrequest_status_t — RV_CANCEL은 UR_FAILED(4)로 보고됨 (UR_CANCELED는
    // user-initiated cancel만, RV_CANCEL은 handler-initiated라 FAILED). 둘 다 비-SUCCESS.
    expect([3, 4]).toContain(blockedEvent.requestStatus);
  });

  test("webRequest:before-request 이벤트 — listener 도달 + URL 페이로드", async () => {
    const listenerKey = await page.evaluate(() => {
      const events: any[] = [];
      const off = (window as any).__suji__.on(
        "webRequest:before-request",
        (payload: string) => {
          try { events.push(JSON.parse(payload)); } catch { events.push(payload); }
        },
      );
      const reg = ((window as any).__wr_test__ ||= {});
      const k = String(Math.random());
      reg[k] = { events, off };
      return k;
    });

    const tag = `before-${Date.now()}`;
    await page.evaluate(async (t) => {
      await fetch(window.location.origin + "/?t=" + t).catch(() => {});
    }, tag);

    const found = await page.evaluate(
      async ({ k, tag }) => {
        const reg = (window as any).__wr_test__;
        const c = reg[k];
        const start = Date.now();
        while (Date.now() - start < 5000) {
          const hit = c.events.find((e: any) =>
            typeof e.url === "string" && e.url.includes(tag),
          );
          if (hit) {
            c.off();
            delete reg[k];
            return hit;
          }
          await new Promise((r) => setTimeout(r, 100));
        }
        c.off();
        delete reg[k];
        return null;
      },
      { k: listenerKey, tag },
    );
    expect(found).not.toBeNull();
    expect(typeof found.url).toBe("string");
    expect(found.url).toContain(tag);
  });

  test("middle wildcard 매칭 — `*/blocked-mid/*`은 origin 무관하게 path 매칭", async () => {
    await core({
      cmd: "web_request_set_blocked_urls",
      patterns: ["*/blocked-mid/*"],
    });
    const result = await page.evaluate(async () => {
      try {
        await fetch(window.location.origin + "/blocked-mid/anything");
        return { ok: true };
      } catch (e: any) {
        return { ok: false, error: String(e.message ?? e) };
      }
    });
    expect(result.ok).toBe(false);
  });

  test("패턴 32개 한계 — 33개 등록 시 32개로 truncate", async () => {
    const patterns = Array.from({ length: 33 }, (_, i) => `https://truncate-${i}/*`);
    const r = await core<{ count: number }>({
      cmd: "web_request_set_blocked_urls",
      patterns,
    });
    expect(r.count).toBe(32);
  });
});
