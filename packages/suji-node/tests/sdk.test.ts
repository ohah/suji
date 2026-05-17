/**
 * @suji/node SDK 단위 테스트 — 1 기능 1 테스트
 *
 * `globalThis.suji` 브릿지가 주입되지 않은 상태에서의 계약 검증.
 * (Suji 앱 안에서 실행될 때의 실제 동작은 E2E에서 검증.)
 *
 * 실행: `bun test packages/suji-node/tests/sdk.test.ts`
 */
import { describe, test, expect, beforeEach } from "bun:test";
import {
  quit,
  platform,
  PLATFORM_MACOS,
  PLATFORM_LINUX,
  PLATFORM_WINDOWS,
  BrowserWindow,
} from "../src/index";

beforeEach(() => {
  // 각 테스트가 자기 브릿지를 세팅/해제 (전역 오염 방지)
  (globalThis as any).suji = undefined;
});

describe("platform constants", () => {
  test("PLATFORM_MACOS 값", () => expect(PLATFORM_MACOS).toBe("macos"));
  test("PLATFORM_LINUX 값", () => expect(PLATFORM_LINUX).toBe("linux"));
  test("PLATFORM_WINDOWS 값", () => expect(PLATFORM_WINDOWS).toBe("windows"));
});

describe("bridge absent", () => {
  test("quit() throws when bridge missing", () => {
    expect(() => quit()).toThrow(/bridge not available/);
  });

  test("platform() throws when bridge missing", () => {
    expect(() => platform()).toThrow(/bridge not available/);
  });
});

describe("bridge stubbed", () => {
  test("quit() delegates to bridge.quit", () => {
    let called = false;
    (globalThis as any).suji = {
      quit: () => {
        called = true;
      },
      platform: () => "macos",
      handle: () => {},
      invoke: async () => "",
      invokeSync: () => "",
      send: () => {},
      on: () => 0,
      off: () => {},
      register: () => {},
    };
    quit();
    expect(called).toBe(true);
  });

  test("platform() returns bridge.platform()", () => {
    (globalThis as any).suji = {
      quit: () => {},
      platform: () => "linux",
      handle: () => {},
      invoke: async () => "",
      invokeSync: () => "",
      send: () => {},
      on: () => 0,
      off: () => {},
      register: () => {},
    };
    expect(platform()).toBe("linux");
  });
});

describe("BrowserWindow (OO wrapper)", () => {
  function stub() {
    const calls: Array<[string, string]> = [];
    (globalThis as any).suji = {
      quit: () => {}, platform: () => "macos", handle: () => {},
      invoke: async (backend: string, json: string) => {
        calls.push([backend, json]);
        return JSON.stringify({ windowId: 7, url: "http://x" });
      },
      invokeSync: () => "", send: () => {}, on: () => 0, off: () => {}, register: () => {},
    };
    return calls;
  }

  test("create() → 인스턴스 + create_window 라우팅 + windowId", async () => {
    const calls = stub();
    const win = await BrowserWindow.create({ title: "X" });
    expect(win).toBeInstanceOf(BrowserWindow);
    expect(win.id).toBe(7);
    expect(calls[0][0]).toBe("__core__");
    expect(JSON.parse(calls[0][1])).toEqual({ cmd: "create_window", title: "X" });
  });

  test("fromId() + 메서드가 this.id로 windows.* 위임", async () => {
    const calls = stub();
    const win = BrowserWindow.fromId(3);
    expect(win.id).toBe(3);
    await win.setTitle("T");
    expect(JSON.parse(calls[0][1])).toEqual({ cmd: "set_title", windowId: 3, title: "T" });
    const u = await win.getURL();
    expect(u.url).toBe("http://x");
    expect(JSON.parse(calls[1][1])).toEqual({ cmd: "get_url", windowId: 3 });
  });
});

describe("windows.setUserAgent/getUserAgent (node)", () => {
  function stubUA() {
    const calls: Array<[string, string]> = [];
    (globalThis as any).suji = {
      quit: () => {}, platform: () => "macos", handle: () => {},
      invoke: async (b: string, j: string) => { calls.push([b, j]); return JSON.stringify({ ok: true, userAgent: "Suji/1.0" }); },
      invokeSync: () => "", send: () => {}, on: () => 0, off: () => {}, register: () => {},
    };
    return calls;
  }
  test("BrowserWindow.setUserAgent/getUserAgent 위임", async () => {
    const calls = stubUA();
    const win = BrowserWindow.fromId(8);
    await win.setUserAgent("UA-X");
    expect(JSON.parse(calls[0][1])).toEqual({ cmd: "set_user_agent", windowId: 8, userAgent: "UA-X" });
    const r = await win.getUserAgent();
    expect(r.userAgent).toBe("Suji/1.0");
    expect(JSON.parse(calls[1][1])).toEqual({ cmd: "get_user_agent", windowId: 8 });
  });
});

describe("windows.capturePage (node)", () => {
  test("capture_page 라우팅 + page-captured 이벤트 resolve (path 매칭)", async () => {
    const calls: string[] = [];
    let evCb: ((ch: string, raw: string) => void) | null = null;
    (globalThis as any).suji = {
      quit: () => {}, platform: () => "macos", handle: () => {},
      invoke: async (_b: string, j: string) => { calls.push(j); return JSON.stringify({ ok: true }); },
      invokeSync: () => "", send: () => {},
      on: (_e: string, cb: (ch: string, raw: string) => void) => { evCb = cb; return () => {}; },
      off: () => {}, register: () => {},
    };
    const p = BrowserWindow.fromId(4).capturePage("/t.png");
    expect(JSON.parse(calls[0])).toEqual({ cmd: "capture_page", windowId: 4, path: "/t.png" });
    evCb!("window:page-captured", JSON.stringify({ path: "/other.png", success: true })); // 무시
    evCb!("window:page-captured", JSON.stringify({ path: "/t.png", success: true }));
    expect(await p).toEqual({ success: true });
  });
});
