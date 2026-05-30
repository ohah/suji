/**
 * #60 part 2 회귀 가드 — Windows ReleaseSafe/ReleaseFast 렌더러 V8 stack-overflow.
 *
 * 버그: 최적화 빌드(RS/Fast)가 호스트 로직을 main() 으로 인라인해 main() 프레임이
 * 수 MB 로 비대해지고, 렌더러 서브프로세스가 그 거대 프레임 "위에서" cef_execute_process
 * 를 돌리며 V8 컨텍스트 부트스트랩(Genesis::CompileExtension) 중 Isolate::StackOverflow
 * → ud2 크래시 → onContextCreated 미발화 → window.__suji__ 미바인딩 → 빈 화면.
 * 수정: 호스트 로직을 runHost() 로 분리(@call(.never_inline, ...))해 main() 프레임을
 * 작게 유지(src/main.zig). Debug 는 인라인이 없어 통과했으므로 이 가드는 반드시
 * **ReleaseSafe 빌드**에서 실행해야 의미가 있다 (run-releasesafe-renderer-boot.sh 가
 * `zig build -Doptimize=ReleaseSafe` 후 호출).
 *
 * 검증: getMainPage 가 window.__suji__.core 바인딩을 기다린다 — 렌더러가 V8 컨텍스트를
 * 만들지 못하면(=#60 재발) 타임아웃으로 던진다. 즉 이 테스트가 통과 = 렌더러 부팅 정상.
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  // getMainPage 는 __suji__.core 가 바인딩될 때까지 대기 — #60 재발 시 여기서 throw.
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
}, 30000);

afterAll(async () => {
  await browser?.disconnect();
});

describe("ReleaseSafe 렌더러 V8 부트스트랩 (#60 part 2 회귀 가드)", () => {
  test("렌더러가 V8 컨텍스트를 만들고 window.__suji__ 를 바인딩한다", async () => {
    const hasCore = await page.evaluate(
      () => typeof (window as any).__suji__?.core === "function",
    );
    expect(hasCore).toBe(true);
  });

  test("기능 보존 — invoke('ping') 왕복 정상 (렌더러 컨텍스트 살아있음)", async () => {
    const r = await page.evaluate(() =>
      (window as any).__suji__.invoke("ping", {}, { target: "zig" }),
    );
    expect(r).toBeDefined();
  });
});
