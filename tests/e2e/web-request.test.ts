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

describe("webRequest dynamic listener (RV_CONTINUE_ASYNC)", () => {
  // 각 테스트 간 listener filter 격리.
  afterEach(async () => {
    await core({ cmd: "web_request_set_listener_filter", patterns: [] });
  });

  // 알려진 한계: cancel/allow round-trip 두 e2e가 5초 timeout. RV_CONTINUE_ASYNC가
  // 정확하게 callback hold하지만 will-request 이벤트의 IO→V8 marshal과 resolve IPC →
  // IO thread callback->cont 사이의 thread/timing race로 추정. 단위/grep + invalid
  // resolve + filter 미등록 path는 통과. listener round-trip 실 동작은 후속 디버깅
  // (예: cef.zig log + thread post task) 단계로 보류.
  test("listener가 callback({cancel:true})로 차단 → fetch fail", async () => {
    await core({
      cmd: "web_request_set_listener_filter",
      patterns: ["https://dynamic-cancel.suji.invalid/*"],
    });

    const result = await page.evaluate(async () => {
      const off = (window as any).__suji__.on(
        "webRequest:will-request",
        (payload: any) => {
          const ev = typeof payload === "string" ? JSON.parse(payload) : payload;
          (window as any).__suji__.core(JSON.stringify({
            cmd: "web_request_resolve",
            id: ev.id,
            cancel: true,
          }));
        },
      );
      try {
        try {
          await fetch("https://dynamic-cancel.suji.invalid/x");
          return { ok: true };
        } catch {
          return { ok: false };
        }
      } finally {
        off();
      }
    });
    expect(result.ok).toBe(false);
  });

  test("listener가 callback({})로 통과 시키면 fetch 정상 완료 (404 OK)", async () => {
    // localhost vite는 404 반환하지만 fetch 자체는 통과 — listener allow 검증용.
    await core({
      cmd: "web_request_set_listener_filter",
      patterns: ["*/dynamic-allow/*"],
    });

    const result = await page.evaluate(async () => {
      const off = (window as any).__suji__.on(
        "webRequest:will-request",
        (payload: any) => {
          const ev = typeof payload === "string" ? JSON.parse(payload) : payload;
          (window as any).__suji__.core(JSON.stringify({
            cmd: "web_request_resolve",
            id: ev.id,
            cancel: false,
          }));
        },
      );
      try {
        try {
          const resp = await fetch(window.location.origin + "/dynamic-allow/test");
          return { ok: true, status: resp.status };
        } catch (e: any) {
          return { ok: false, error: String(e.message ?? e) };
        }
      } finally {
        off();
      }
    });
    expect(result.ok).toBe(true);
  });

  test("invalid resolve id는 success=false", async () => {
    const r = await core<{ success: boolean }>({
      cmd: "web_request_resolve",
      id: 9999999,
      cancel: false,
    });
    expect(r.success).toBe(false);
  });

  test("listener filter 미등록 URL은 RV_CONTINUE — listener 미발화", async () => {
    // filter 패턴 없어 unrelated URL은 will-request 이벤트 미발화.
    await core({
      cmd: "web_request_set_listener_filter",
      patterns: ["https://specific-only.suji.invalid/*"],
    });

    const fired = await page.evaluate(async () => {
      let count = 0;
      const off = (window as any).__suji__.on("webRequest:will-request", () => {
        count += 1;
      });
      try {
        await fetch(window.location.origin + "/").catch(() => {});
        await new Promise((r) => setTimeout(r, 800));
      } finally {
        off();
      }
      return count;
    });
    expect(fired).toBe(0);
  });
});
