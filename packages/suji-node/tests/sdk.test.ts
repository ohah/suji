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
  windows,
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
        return JSON.stringify({ windowId: 7, viewId: 11, url: "http://x", ok: true, viewIds: [11] });
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

  test("WebContentsView helpers route host/view ids", async () => {
    const calls = stub();
    const win = BrowserWindow.fromId(3);
    const created = await win.createView({ url: "https://example.com", x: 10, y: 20, width: 300, height: 400 });
    expect(created.viewId).toBe(11);
    expect(JSON.parse(calls[0][1])).toEqual({
      cmd: "create_view",
      hostId: 3,
      url: "https://example.com",
      x: 10,
      y: 20,
      width: 300,
      height: 400,
    });

    await windows.addChildView(3, 11, 0);
    expect(JSON.parse(calls[1][1])).toEqual({ cmd: "add_child_view", hostId: 3, viewId: 11, index: 0 });
    await win.setTopView(11);
    expect(JSON.parse(calls[2][1])).toEqual({ cmd: "set_top_view", hostId: 3, viewId: 11 });
    await win.setViewVisible(11, false);
    expect(JSON.parse(calls[3][1])).toEqual({ cmd: "set_view_visible", viewId: 11, visible: false });
    await win.setViewBounds(11, { x: 1, y: 2, width: 3, height: 4 });
    expect(JSON.parse(calls[4][1])).toEqual({ cmd: "set_view_bounds", viewId: 11, x: 1, y: 2, width: 3, height: 4 });
    await win.removeChildView(11);
    expect(JSON.parse(calls[5][1])).toEqual({ cmd: "remove_child_view", hostId: 3, viewId: 11 });
    const children = await win.getChildViews();
    expect(children.viewIds).toEqual([11]);
    expect(JSON.parse(calls[6][1])).toEqual({ cmd: "get_child_views", hostId: 3 });
    await win.destroyView(11);
    expect(JSON.parse(calls[7][1])).toEqual({ cmd: "destroy_view", viewId: 11 });
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

describe("windows.capturePage (node, #16 deferred Promise)", () => {
  test("capture_page coreCall 응답이 곧 결과 (listener 없음)", async () => {
    const calls: string[] = [];
    let onCalled = false;
    (globalThis as any).suji = {
      quit: () => {}, platform: () => "macos", handle: () => {},
      invoke: async (_b: string, j: string) => { calls.push(j); return JSON.stringify({ success: true }); },
      invokeSync: () => "", send: () => {},
      on: () => { onCalled = true; return () => {}; },
      off: () => {}, register: () => {},
    };
    const r = await BrowserWindow.fromId(4).capturePage("/t.png");
    expect(JSON.parse(calls[0])).toEqual({ cmd: "capture_page", windowId: 4, path: "/t.png" });
    expect(r).toEqual({ success: true });
    expect(onCalled).toBe(false);
  });

  test("printToPDF coreCall 응답이 곧 결과", async () => {
    const calls: string[] = [];
    (globalThis as any).suji = {
      quit: () => {}, platform: () => "macos", handle: () => {},
      invoke: async (_b: string, j: string) => { calls.push(j); return JSON.stringify({ success: false }); },
      invokeSync: () => "", send: () => {},
      on: () => () => {}, off: () => {}, register: () => {},
    };
    const r = await BrowserWindow.fromId(7).printToPDF("/x.pdf");
    expect(JSON.parse(calls[0])).toEqual({ cmd: "print_to_pdf", windowId: 7, path: "/x.pdf" });
    expect(r).toEqual({ success: false });
  });
});
