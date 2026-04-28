/**
 * 스플래시 스크린 패턴 E2E — Electron 의 BrowserWindow 조합 / Tauri의 splashscreen
 * 플러그인 동등. Suji는 별도 API 없이 windows.create + isLoading polling + close
 * 조합으로 표현 (또는 ready-to-show 이벤트 — 본 e2e는 더 단순한 isLoading false polling).
 *
 * 시나리오: dev 시작 시 메인 창 windowId=1 떠 있음. splash 창 추가 생성 →
 * isLoading=false까지 polling → splash destroy. 메인 창은 그대로.
 *
 * 실행: ./tests/e2e/run-splash.sh
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
  page = (await browser.pages())[0];
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("splash window 패턴", () => {
  test("splash 생성 → isLoading=false 도달 → close, main 창은 살아있음", async () => {
    // 1. splash 창 생성 (BrowserWindow.create + frame:false 옵션이 일반적이지만
    //    e2e는 default frame).
    const splash = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "splash",
      x: 200, y: 200, width: 400, height: 200,
    });
    expect(splash.windowId).toBeGreaterThan(0);

    // 2. 로드 완료까지 polling — Electron의 isReady/ready-to-show 동등.
    let loaded = false;
    for (let i = 0; i < 80; i++) {
      const r = await core<{ loading: boolean }>({
        cmd: "is_loading",
        windowId: splash.windowId,
      });
      if (r.loading === false) {
        loaded = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    expect(loaded).toBe(true);

    // 3. splash 종료 — destroy_window IPC는 현재 silent (response 검증 없이 호출만).
    //    실제 패턴에서는 cleanup point. window destroy IPC 미구현 (TODO #known).
    await core({ cmd: "destroy_window", windowId: splash.windowId });

    // 4. 원본 메인 창은 그대로 — windowId=1 getURL 정상 응답.
    const mainUrl = await core<{ url: string }>({ cmd: "get_url", windowId: 1 });
    expect(typeof mainUrl.url).toBe("string");
    expect(mainUrl.url.length).toBeGreaterThan(0);
  });
});
