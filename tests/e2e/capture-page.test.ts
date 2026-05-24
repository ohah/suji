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
import { getMainPage } from "./_page";
import { existsSync, statSync, readFileSync, unlinkSync } from "node:fs";

let browser: Browser;
let page: Page;
let capturedPath: string | null = null; // afterAll 정리(assert 실패 시 leftover 방지)
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
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
});

afterAll(async () => {
  if (capturedPath && existsSync(capturedPath)) unlinkSync(capturedPath);
  await browser?.disconnect();
});

describe("capture_page (CDP Page.captureScreenshot)", () => {
  test("ack ok + window:page-captured 이벤트 + 실 PNG 파일(매직바이트) 생성", async () => {
    const path = `/tmp/suji-e2e-capture-${Date.now()}.png`;
    capturedPath = path; // assert 실패해도 afterAll 이 정리

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

  // 부분 영역 캡처 (Electron `capturePage(rect)`) — clip PNG 의 IHDR width 가
  // 전체 캡처보다 작은지로 검증(DPR 무관 — 둘 다 동일 배율).
  test("clipWidth/Height 지정 → 더 작은 영역 PNG (CDP clip)", async () => {
    const pngWidth = (p: string): number => readFileSync(p).readUInt32BE(16);

    const waitCaptured = (p: string) =>
      page.evaluate(
        (pp) =>
          new Promise<boolean>((resolve) => {
            const off = (window as any).__suji__.on("window:page-captured", (d: any) => {
              if (d.path === pp) { off(); resolve(d.success === true); }
            });
          }),
        p,
      ) as Promise<boolean>;

    const fullPath = `/tmp/suji-e2e-cap-full-${Date.now()}.png`;
    const clipPath = `/tmp/suji-e2e-cap-clip-${Date.now()}.png`;

    const fullDone = waitCaptured(fullPath);
    await core({ cmd: "capture_page", windowId, path: fullPath });
    expect(await Promise.race([fullDone, new Promise((r) => setTimeout(() => r(false), 10000))])).toBe(true);

    const clipDone = waitCaptured(clipPath);
    const ack: any = await core({
      cmd: "capture_page", windowId, path: clipPath,
      clipX: 0, clipY: 0, clipWidth: 64, clipHeight: 48,
    });
    expect(ack.ok).toBe(true);
    expect(await Promise.race([clipDone, new Promise((r) => setTimeout(() => r(false), 10000))])).toBe(true);

    expect(existsSync(clipPath)).toBe(true);
    const csig = readFileSync(clipPath).subarray(0, 8);
    expect([...csig]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    // clip(64px) PNG 가 전체 캡처보다 좁아야 함(부분 영역 실효 검증).
    expect(pngWidth(clipPath)).toBeLessThan(pngWidth(fullPath));
    unlinkSync(fullPath);
    unlinkSync(clipPath);
  });
});
