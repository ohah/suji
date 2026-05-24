/**
 * contextIsolation E2E — window.__suji__ frozen-proxy 하드닝 실증.
 *
 * onContextCreated 가 모든 멤버 조립 후 window.__suji__ 슬롯을
 * non-writable/non-configurable 로 봉인 + Object.freeze. 실 CEF 렌더러
 * JS 에서 직접 관찰되는 보안 속성을 실증:
 *   1. 기능 보존 — invoke("ping") 정상
 *   2. Object.isFrozen(__suji__) === true
 *   3. 메서드 재할당 무효(원본 유지) / delete 실패
 *   4. window.__suji__ 슬롯 교체·삭제 불가(non-writable/non-configurable)
 *   5. 변조 시도 후에도 invoke 정상(실 bridge 무손상)
 *
 * 한계(정직): 우리 바인드보다 *먼저* 실행된 스크립트는 못 막음
 * (메인 월드 frozen — Chrome isolated-world 아님). docs/PLAN Phase 7.
 *
 * 실행: tests/e2e/run-context-isolation.sh
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
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
}, 30000);

afterAll(async () => {
  await browser?.disconnect();
});

describe("contextIsolation — window.__suji__ frozen 하드닝", () => {
  test("기능 보존 — invoke('ping') 정상 (freeze 가 bridge 안 깸)", async () => {
    const r = await page.evaluate(() =>
      (window as any).__suji__.invoke("ping", {}, { target: "zig" }),
    );
    expect(r).toBeDefined();
  });

  test("Object.isFrozen(__suji__) === true", async () => {
    const frozen = await page.evaluate(() => Object.isFrozen((window as any).__suji__));
    expect(frozen).toBe(true);
  });

  test("메서드 재할당 무효(원본 유지) + delete 실패", async () => {
    const res = await page.evaluate(() => {
      const s: any = (window as any).__suji__;
      const orig = s.invoke;
      try { s.invoke = function () { return "EVIL"; }; } catch {}
      const reassignBlocked = s.invoke === orig;
      let delRet: boolean;
      try { delRet = (delete s.invoke); } catch { delRet = false; }
      const stillHas = typeof s.invoke === "function" && "invoke" in s;
      return { reassignBlocked, delRet, stillHas };
    });
    expect(res.reassignBlocked).toBe(true);
    expect(res.delRet).toBe(false);
    expect(res.stillHas).toBe(true);
  });

  test("window.__suji__ 슬롯 봉인 — 교체/삭제 불가, descriptor non-writable/non-configurable", async () => {
    const res = await page.evaluate(() => {
      const orig = (window as any).__suji__;
      try { (window as any).__suji__ = { invoke: () => "EVIL" }; } catch {}
      const replaceBlocked = (window as any).__suji__ === orig;
      let delRet: boolean;
      try { delRet = (delete (window as any).__suji__); } catch { delRet = false; }
      const d = Object.getOwnPropertyDescriptor(window, "__suji__")!;
      return { replaceBlocked, delRet, writable: d.writable, configurable: d.configurable };
    });
    expect(res.replaceBlocked).toBe(true);
    expect(res.delRet).toBe(false);
    expect(res.writable).toBe(false);
    expect(res.configurable).toBe(false);
  });

  test("변조 시도 후에도 invoke('ping') 여전히 정상 (실 bridge 무손상)", async () => {
    const r = await page.evaluate(() => {
      const s: any = (window as any).__suji__;
      try { s.invoke = () => Promise.resolve("EVIL"); } catch {}
      try { s.core = null; } catch {}
      return s.invoke("ping", {}, { target: "zig" });
    });
    expect(r).toBeDefined();
    expect(r).not.toBe("EVIL");
  });
});
