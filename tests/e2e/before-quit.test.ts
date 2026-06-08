/**
 * app:before-quit behavioral e2e — quit 트리거 시 백엔드 before-quit 핸들러가 프로세스
 * 종료 전에 실제로 발화하는지 검증. quit 은 프로세스를 죽여 puppeteer 로 직접 관측이
 * 불가하므로, Zig 백엔드(examples/multi-backend)가 app:before-quit 에서 마커 파일을
 * 기록(SUJI_E2E_BQ_MARKER 게이트)하고 — 프로세스 종료 후 디스크에서 회수해 assert.
 *
 * 실행: ./tests/e2e/run-before-quit.sh
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";
import { existsSync } from "node:fs";

let browser: Browser;
let page: Page;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser, 30000);
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  try {
    await browser?.disconnect();
  } catch {
    /* quit 으로 이미 끊김 — 정상 */
  }
});

describe("app:before-quit (behavioral)", () => {
  test("quit → 백엔드 before-quit 핸들러가 종료 전 마커 기록", async () => {
    const marker = process.env.SUJI_E2E_BQ_MARKER;
    expect(marker).toBeTruthy();
    expect(existsSync(marker!)).toBe(false); // 사전: 마커 없음(run 스크립트가 rm)

    // quit cmd → cef.quit() chokepoint 에서 app:before-quit 동기 발화 → Zig 백엔드
    // onBeforeQuit 가 마커 기록 → 그 뒤 message loop 종료. 프로세스 종료로 인한
    // puppeteer disconnect 는 기대된 동작.
    try {
      await page.evaluate(() => (window as any).__suji__.core(JSON.stringify({ cmd: "quit" })));
    } catch {
      /* 종료 disconnect — 정상 */
    }

    // 백엔드 핸들러가 마커를 쓸 때까지 폴링(프로세스가 죽어도 디스크 파일은 남는다).
    let appeared = false;
    for (let i = 0; i < 50; i++) {
      if (existsSync(marker!)) {
        appeared = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    expect(appeared).toBe(true);
  });
});
