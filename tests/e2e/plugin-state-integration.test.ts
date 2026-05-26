/**
 * 공식 state 플러그인 + JS wrapper 통합 e2e.
 *
 * 검증 범위:
 *   1. renderer 가 __suji__.invoke('state:set'/'get'/'delete'/'keys'/'clear') 로
 *      실제 plugin DLL 호출 → 라운드트립 성공
 *   2. plugin DLL 이 Windows/macOS/Linux 양쪽 dlopen 후 invoke 동형
 *   3. JS wrapper 의 wire contract (channel='state:get', payload={key}, 응답
 *      result.value) 가 multi-backend 의 실 state plugin 응답과 일치
 *
 * Wrapper 의 unit-level wire shape 은 `bun test plugins/state/js/src` 96/96 이
 * 별도 검증. 이 파일은 REAL plugin DLL ↔ renderer 통합만 검사.
 *
 * sqlite plugin 은 multi-backend 에 미활성 — 분리된 fixture 필요. zig
 * build test-sqlite (14/14) 가 plugin 자체 동작은 검증.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = unknown>(req: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (r) => (window as unknown as { __suji__: { invoke: (ch: string, d?: unknown) => unknown } }).__suji__
      .invoke(r.channel as string, r.payload as Record<string, unknown> | undefined),
    { channel: req.channel as string, payload: req.payload },
  ) as Promise<T>;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
  await page.waitForFunction(() => typeof (window as any).__suji__ !== "undefined", { timeout: 10000 });
  // 사전 정리.
  await core({ channel: "state:clear", payload: {} });
});

afterAll(async () => {
  try {
    await core({ channel: "state:clear", payload: {} });
  } catch {}
  await browser?.disconnect();
});

describe("state plugin + JS wrapper integration (real DLL roundtrip)", () => {
  test("set + get round-trip", async () => {
    const setResp = await core<{ result?: unknown }>({
      channel: "state:set",
      payload: { key: "user", value: { name: "yoon" } },
    });
    expect(setResp).toBeDefined();
    const getResp = await core<{ result?: { value?: { name: string } } }>({
      channel: "state:get",
      payload: { key: "user" },
    });
    expect(getResp?.result?.value).toEqual({ name: "yoon" });
  });

  test("get on missing key returns null/undefined", async () => {
    const r = await core<{ result?: { value?: unknown } }>({
      channel: "state:get",
      payload: { key: "missing-key-zzz" },
    });
    // wrapper 가 result?.value ?? null 로 정규화. plugin 은 missing 시 result.value=null.
    expect(r?.result?.value == null).toBe(true);
  });

  test("delete removes key", async () => {
    await core({ channel: "state:set", payload: { key: "tmp", value: 42 } });
    await core({ channel: "state:delete", payload: { key: "tmp" } });
    const r = await core<{ result?: { value?: unknown } }>({
      channel: "state:get",
      payload: { key: "tmp" },
    });
    expect(r?.result?.value == null).toBe(true);
  });

  test("keys (scope:global) returns prefix-stripped user keys", async () => {
    await core({ channel: "state:clear", payload: {} });
    await core({ channel: "state:set", payload: { key: "a", value: 1 } });
    await core({ channel: "state:set", payload: { key: "b", value: 2 } });
    // scope 명시 → user-key 만(prefix 제거). 미지정이면 raw prefix 포함.
    const r = await core<{ result?: { keys?: string[] } }>({
      channel: "state:keys",
      payload: { scope: "global" },
    });
    const keys = r?.result?.keys ?? [];
    expect(keys.sort()).toEqual(["a", "b"]);
  });

  test("keys (no-scope) returns raw prefixed keys", async () => {
    await core({ channel: "state:clear", payload: {} });
    await core({ channel: "state:set", payload: { key: "a", value: 1 } });
    const r = await core<{ result?: { keys?: string[] } }>({
      channel: "state:keys",
      payload: {},
    });
    // wrapper 의 'no-scope = 전체 키' 컨벤션 — global::a 형태 그대로.
    expect(r?.result?.keys ?? []).toContain("global::a");
  });

  test("clear removes all keys", async () => {
    await core({ channel: "state:set", payload: { key: "x", value: 1 } });
    await core({ channel: "state:clear", payload: {} });
    const r = await core<{ result?: { keys?: string[] } }>({
      channel: "state:keys",
      payload: {},
    });
    expect(r?.result?.keys ?? []).toEqual([]);
  });

  test("scope: window scope set/get isolation", async () => {
    await core({
      channel: "state:set",
      payload: { key: "view", value: "split", scope: "window:1" },
    });
    const r1 = await core<{ result?: { value?: string } }>({
      channel: "state:get",
      payload: { key: "view", scope: "window:1" },
    });
    expect(r1?.result?.value).toBe("split");
    // 다른 scope 에서는 보이지 않음.
    const r2 = await core<{ result?: { value?: unknown } }>({
      channel: "state:get",
      payload: { key: "view", scope: "window:2" },
    });
    expect(r2?.result?.value == null).toBe(true);
  });

  test("JS wrapper API shape: result envelope unwrap", async () => {
    await core({ channel: "state:set", payload: { key: "wrapper-test", value: "abc" } });
    // wrapper 코드는 result?.result?.value 로 언랩 — 실 응답이 이 nested 구조인지.
    const raw = await page.evaluate(() =>
      (window as unknown as { __suji__: { invoke: (ch: string, d?: unknown) => Promise<unknown> } }).__suji__.invoke(
        "state:get",
        { key: "wrapper-test" },
      ),
    );
    expect((raw as { result?: { value?: string } })?.result?.value).toBe("abc");
  });
});
