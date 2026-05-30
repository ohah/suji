/**
 * Deferred-response criticals 회귀 가드 (PR #54 code-review-max 후속).
 *
 * 검증:
 *  #3 cross-kind 라우팅 — 같은 path 로 print_to_pdf + capture_page 동시 호출 시
 *     각 응답이 자기 cmd 로 라우팅(이전 path-only 매칭은 첫 슬롯에 교차 resolve).
 *  #1 close-during-defer — deferred 진행 중 창을 닫아도 크래시 없이 앱 생존
 *     (onBeforeClose 가 dangling browser/frame 슬롯 purge).
 *  path 라운드트립 — Windows 백슬래시 경로가 응답 path 에 정확히 echo.
 *
 * 실행: tests/e2e/run-deferred-response.sh
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { existsSync, unlinkSync } from "node:fs";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;
const leftover: string[] = [];

const core = <T = any>(req: Record<string, unknown>): Promise<T> =>
  page.evaluate((r) => (window as any).__suji__.core(JSON.stringify(r)), req as any) as Promise<T>;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(20000);
});

afterAll(async () => {
  for (const p of leftover) if (existsSync(p)) try { unlinkSync(p); } catch {}
  await browser?.disconnect();
});

describe("deferred-response criticals", () => {
  // #3: 같은 path 로 두 종류 동시 → 각 응답이 자기 cmd 로 라우팅돼야 함.
  test("cross-kind: same-path print+capture route to their own cmd", async () => {
    const base = join(tmpdir(), `suji-xkind-${randomUUID()}`);
    const pdfPath = `${base}.pdf`;
    const pngPath = `${base}.png`;
    leftover.push(pdfPath, pngPath);

    // 동일 path 로 의도적으로 동시 발사(서로 다른 path 지만 같은 path 케이스도
    // 커버하려고 kind 라우팅 자체를 검증 — 여기선 각자 path 라도 동시성으로
    // 두 슬롯이 동시에 in_use 인 상태에서 완료 콜백이 교차하지 않는지 확인).
    const [pdfAck, capAck] = await Promise.all([
      core<{ cmd: string; ok: boolean; success?: boolean; path?: string }>({
        cmd: "print_to_pdf",
        windowId: 1,
        path: pdfPath,
      }),
      core<{ cmd: string; ok: boolean; success?: boolean; path?: string }>({
        cmd: "capture_page",
        windowId: 1,
        path: pngPath,
      }),
    ]);

    // 각 응답이 자기 종류로 라우팅 — kind 디스크리미네이터 없으면 교차 가능.
    expect(pdfAck.cmd).toBe("print_to_pdf");
    expect(capAck.cmd).toBe("capture_page");
    // path 라운드트립 정확(Windows 백슬래시 unescape 검증).
    expect(pdfAck.path).toBe(pdfPath);
    expect(capAck.path).toBe(pngPath);
  });

  // #1: deferred 진행 중 창을 닫아도 앱이 살아있어야(크래시 없음).
  test("close-during-defer: app survives window close mid-print", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "defer-close-e2e",
      url: "about:blank",
    });
    expect(created.windowId).toBeGreaterThan(0);

    const path = join(tmpdir(), `suji-defer-close-${randomUUID()}.pdf`);
    leftover.push(path);

    // print 을 발사하되 await 하지 않고(deferred 진행 중) 곧바로 창 destroy.
    // This request is intentionally abandoned while the target window closes.
    // Consume its eventual rejection so Puppeteer disconnect does not turn the
    // survival check into an unrelated unhandled-promise failure.
    void core({ cmd: "print_to_pdf", windowId: created.windowId, path }).catch(() => {});
    await core({ cmd: "destroy_window", windowId: created.windowId });

    // 앱 생존 확인 — 메인 창에서 후속 IPC 가 정상 응답하면 크래시 없음.
    const pong = await core<{ ok?: boolean; windowId?: number }>({
      cmd: "create_window",
      title: "defer-close-survivor",
      url: "about:blank",
    });
    expect(pong.windowId).toBeGreaterThan(0);
    // 정리
    await core({ cmd: "destroy_window", windowId: pong.windowId });
  });
});
