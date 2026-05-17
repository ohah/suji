/**
 * capture_page E2E — CDP Page.captureScreenshot → 실 PNG 파일 생성 실증.
 *
 * printToPDF 와 동형 2단(ack 즉시 + `window:page-captured`{path,success}
 * 이벤트). 실 CEF 브라우저에서 CDP send_dev_tools_message → observer →
 * base64 디코드 → 파일쓰기 전 경로를 실증(단위 테스트는 mock 기반).
 *
 * 실행: tests/e2e/run-capture-page.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { existsSync, statSync, readFileSync, unlinkSync } from "node:fs";

let browser: Browser;
let page: Page;
const windowId = 1; // multi-backend 첫 창(실 프론트엔드 콘텐츠)

const core = <T = any>(req: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (r) => (window as any).__suji__.core(JSON.stringify(r)),
    req as any,
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

describe("capture_page (CDP Page.captureScreenshot)", () => {
  test("ack ok + window:page-captured 이벤트 + 실 PNG 파일(매직바이트) 생성", async () => {
    const path = `/tmp/suji-e2e-capture-${Date.now()}.png`;

    // 완료 이벤트 listener 등록(SDK 와 동일 — path 매칭).
    const captured = page.evaluate(
      (p) =>
        new Promise<{ path?: string; success?: boolean }>((resolve) => {
          const off = (window as any).__suji__.on(
            "window:page-captured",
            (data: any) => {
              if (data.path === p) {
                off();
                resolve({ path: data.path, success: data.success });
              }
            },
          );
        }),
      path,
    ) as Promise<{ path?: string; success?: boolean }>;

    const ack: any = await core({ cmd: "capture_page", windowId, path });
    expect(ack.cmd).toBe("capture_page");
    expect(ack.ok).toBe(true);

    const result = (await Promise.race([
      captured,
      new Promise((r) => setTimeout(() => r({ path: undefined, success: undefined }), 10000)),
    ])) as { path?: string; success?: boolean };
    expect(result.path).toBe(path);
    expect(result.success).toBe(true);

    // 실 파일: 존재 + 비어있지 않음 + PNG 시그니처.
    expect(existsSync(path)).toBe(true);
    expect(statSync(path).size).toBeGreaterThan(0);
    const sig = readFileSync(path).subarray(0, 8);
    expect([...sig]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    unlinkSync(path);
  });

  test("알 수 없는 windowId — ok:false (이벤트 미발화)", async () => {
    const r: any = await core({ cmd: "capture_page", windowId: 99999, path: "/tmp/x.png" });
    expect(r.cmd).toBe("capture_page");
    expect(r.ok).toBe(false);
  });
});
