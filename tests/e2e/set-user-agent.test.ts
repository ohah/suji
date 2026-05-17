/**
 * set_user_agent / get_user_agent E2E — CDP Network.setUserAgentOverride
 * 가 실 CEF 렌더러의 navigator.userAgent 를 실제로 바꾸는지 실증.
 *
 *  1. set→get 라운드트립 (코어 inline 추적).
 *  2. 새 창에 UA override 적용 후 data: 페이지로 네비 → CDP /json 의
 *     해당 target title(=navigator.userAgent) 이 override 와 일치(실효 증명).
 *
 * 실행: tests/e2e/run-set-user-agent.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;
const windowId = 1;

const core = <T = any>(req: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (r) => (window as any).__suji__.core(JSON.stringify(r)),
    req as any,
  ) as Promise<T>;

async function cdpTargets(): Promise<Array<{ type: string; url: string; title: string }>> {
  const r = await fetch("http://localhost:9222/json");
  return (await r.json()) as Array<{ type: string; url: string; title: string }>;
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
  page.setDefaultTimeout(15000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("set_user_agent / get_user_agent", () => {
  test("set→get 라운드트립 (inline 추적)", async () => {
    const ua = "SujiE2E/9.9 (round-trip)";
    const set: any = await core({ cmd: "set_user_agent", windowId, userAgent: ua });
    expect(set.cmd).toBe("set_user_agent");
    expect(set.ok).toBe(true);
    const get: any = await core({ cmd: "get_user_agent", windowId });
    expect(get.cmd).toBe("get_user_agent");
    expect(get.userAgent).toBe(ua);
  });

  test("CDP override 실효 — 새 창 navigator.userAgent 가 override 반영", async () => {
    const ua = `SujiE2E-UA-${Date.now()}`;
    const created: any = await core({ cmd: "create_window", title: "ua-test", url: "about:blank" });
    const id = created.windowId;
    expect(typeof id).toBe("number");

    const setR: any = await core({ cmd: "set_user_agent", windowId: id, userAgent: ua });
    expect(setR.ok).toBe(true);
    // happy-path 단축용 짧은 settle — 정확성 게이트는 아래 폴링 루프(override
    // 가 load 보다 늦게 적용돼도 title===ua 될 때까지 재시도가 흡수).
    await new Promise((r) => setTimeout(r, 400));

    const marker = `UAMARK_${Date.now()}`;
    const html = `<!--${marker}--><script>document.title=navigator.userAgent</script>`;
    await core({ cmd: "load_url", windowId: id, url: `data:text/html,${encodeURIComponent(html)}` });

    // /json 의 해당 target title(=navigator.userAgent)이 override 와 일치할 때까지 폴링.
    let title = "";
    for (let i = 0; i < 25; i++) {
      await new Promise((r) => setTimeout(r, 400));
      const t = (await cdpTargets()).find(
        (x) => x.type === "page" && x.url.includes(encodeURIComponent(marker)),
      );
      if (t && t.title) {
        title = t.title;
        if (title === ua) break;
      }
    }
    expect(title).toBe(ua);
  });

  test("알 수 없는 windowId — set/get ok:false", async () => {
    const s: any = await core({ cmd: "set_user_agent", windowId: 99999, userAgent: "x" });
    expect(s.ok).toBe(false);
    const g: any = await core({ cmd: "get_user_agent", windowId: 99999 });
    expect(g.ok).toBe(false);
  });
});
