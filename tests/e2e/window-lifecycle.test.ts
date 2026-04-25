/**
 * Window Lifecycle E2E Tests
 *
 * Suji 앱을 CEF 모드로 실행한 상태에서 창 생성/이벤트 발화 경로를 검증한다.
 *
 * 실행 방법:
 *   1. cd examples/zig-backend && ../../zig-out/bin/suji dev
 *      (또는 CEF 렌더러가 http://localhost:9222에서 DevTools를 노출하는 예제)
 *   2. bun test tests/e2e/window-lifecycle.test.ts
 *
 * 범위:
 *   - `__suji__.core` IPC로 `create_window` 호출 → WM 경유 → 새 창 생성
 *   - `window:created` 이벤트가 첫 창 frontend 리스너에 도달
 *   - 응답 객체 형식 (`{from, cmd, windowId}`) 검증 (프론트 측에서 이미 JSON.parse됨)
 *   - 로그 파일이 `~/.suji/logs/` 아래 실제로 생성되는지
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

let browser: Browser;
let page: Page;

type CoreResponse = { from: string; cmd: string; windowId: number };

const coreCall = (request: object): Promise<CoreResponse> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request,
  ) as Promise<CoreResponse>;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 10000,
    // CEF 실제 창 크기를 그대로 사용. 명시 안 하면 puppeteer가 800x600으로 viewport를
    // 강제 emulation해서 window.innerWidth / page.screenshot 결과가 실제 NSWindow와 달라짐.
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  // 메인 창 찾기: http://localhost:51XX/ (vite dev) — about:blank 창들은 이전
  // 테스트 실행에서 누적됐을 수 있으므로 걸러냄.
  const main = pages.find((p) => p.url().startsWith("http://localhost"));
  if (!main) throw new Error("main window (localhost) not found in puppeteer pages");
  page = main;
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

// ============================================
// 1. create_window IPC 경로
// ============================================

describe("create_window IPC", () => {
  test("core() returns object with windowId", async () => {
    const r = await coreCall({ cmd: "create_window", title: "E2E Test", url: "about:blank" });
    expect(r.from).toBe("zig-core");
    expect(r.cmd).toBe("create_window");
    expect(typeof r.windowId).toBe("number");
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("create_window with missing fields uses defaults", async () => {
    const r = await coreCall({ cmd: "create_window" });
    expect(typeof r.windowId).toBe("number");
    expect(r.windowId).toBeGreaterThan(0);
  });

  test("multiple create_window calls yield distinct windowIds", async () => {
    const r1 = await coreCall({ cmd: "create_window", title: "win-a", url: "about:blank" });
    const r2 = await coreCall({ cmd: "create_window", title: "win-b", url: "about:blank" });
    expect(r1.windowId).not.toBe(r2.windowId);
  });
});

// ============================================
// 2. window:created 이벤트 전파
// ============================================

describe("window:created event propagation", () => {
  test("suji.on('window:created') receives event when IPC creates window", async () => {
    // 페이지 콘솔 캡처 (listener 호출 여부 진단용)
    const consoleLogs: string[] = [];
    const handler = (msg: any) => consoleLogs.push(msg.text());
    page.on("console", handler);

    // 리스너 등록
    await page.evaluate(() => {
      (window as any).__test_created = [];
      (window as any).__suji__.on("window:created", (data: any) => {
        console.log("LISTENER HIT:", JSON.stringify(data));
        (window as any).__test_created.push(data);
      });
    });

    const r = await coreCall({ cmd: "create_window", title: "evt-test", url: "about:blank" });

    // 이벤트 dispatch 대기 (CEF execute_java_script는 async)
    await new Promise((r2) => setTimeout(r2, 500));

    const received: any[] = await page.evaluate(() => (window as any).__test_created);
    page.off("console", handler);

    if (received.length === 0) {
      // 진단용: 콘솔 로그 덤프
      console.error("Console during test:", consoleLogs);
    }

    expect(received.length).toBeGreaterThan(0);
    // 데이터가 객체면 windowId 속성 확인, 문자열이면 포함 확인
    const hasOurId = received.some((d) => {
      if (typeof d === "object" && d !== null) return d.windowId === r.windowId;
      return String(d).includes(`"windowId":${r.windowId}`);
    });
    expect(hasOurId).toBe(true);
  });
});

// ============================================
// 3. 로그 파일 — 실행 중 `~/.suji/logs/suji-*.log` 생성
// ============================================

describe("log file output", () => {
  test("current run produced a log file under ~/.suji/logs/", () => {
    const logDir = join(homedir(), ".suji", "logs");
    const entries = readdirSync(logDir).filter((n) => n.startsWith("suji-") && n.endsWith(".log"));
    expect(entries.length).toBeGreaterThan(0);

    // 최근 10분 내 수정된 파일이 있어야 (현재 실행 중인 run의 로그)
    const now = Date.now();
    const recent = entries.some((name) => {
      const st = statSync(join(logDir, name));
      return now - st.mtimeMs < 10 * 60 * 1000;
    });
    expect(recent).toBe(true);
  });
});
