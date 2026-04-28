import { describe, it, expect, mock, beforeEach } from "bun:test";

// __suji__ 브릿지 모킹
const mockBridge = {
  invoke: mock(() => Promise.resolve({ msg: "pong" })),
  on: mock((event: string, cb: Function) => {
    const cancel = mock(() => {});
    return cancel;
  }),
  emit: mock(() => Promise.resolve()),
  chain: mock(() => Promise.resolve({ chain: true })),
  fanout: mock(() => Promise.resolve({ fanout: true })),
  core: mock(() => Promise.resolve({ core: true })),
  off: mock(() => {}),
};

(globalThis as any).window = { __suji__: mockBridge };

// 모듈 import (window.__suji__ 설정 후)
const { invoke, on, once, send, off, fanout, chain, menu, fs: sujiFs, globalShortcut, screen, powerSaveBlocker, safeStorage, app, shell } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
  mockBridge.on.mockClear();
  mockBridge.emit.mockClear();
  mockBridge.chain.mockClear();
  mockBridge.fanout.mockClear();
  mockBridge.off.mockClear();
});

describe("invoke", () => {
  it("calls bridge with channel only", async () => {
    await invoke("ping");
    expect(mockBridge.invoke).toHaveBeenCalledTimes(1);
  });

  it("calls bridge with channel and data", async () => {
    await invoke("greet", { name: "Suji" });
    expect(mockBridge.invoke).toHaveBeenCalledTimes(1);
  });

  it("calls bridge with target option", async () => {
    await invoke("greet", { name: "Suji" }, { target: "rust" });
    expect(mockBridge.invoke).toHaveBeenCalledTimes(1);
  });

  it("returns result", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: 42 });
    const result = await invoke<{ result: number }>("add", { a: 1, b: 2 });
    expect(result.result).toBe(42);
  });
});

describe("on", () => {
  it("registers listener and returns cancel function", () => {
    const cancel = on("test-event", () => {});
    expect(mockBridge.on).toHaveBeenCalledTimes(1);
    expect(typeof cancel).toBe("function");
  });

  it("passes callback to bridge", () => {
    const cb = () => {};
    on("test-event", cb);
    expect(mockBridge.on).toHaveBeenCalledWith("test-event", cb);
  });
});

describe("once", () => {
  it("registers listener", () => {
    once("one-shot", () => {});
    expect(mockBridge.on).toHaveBeenCalledTimes(1);
  });

  it("auto-cancels after first call", () => {
    let cancelCalled = false;
    const mockCancel = () => { cancelCalled = true; };
    mockBridge.on.mockReturnValueOnce(mockCancel);

    let receivedData: unknown = null;
    const cb = (data: unknown) => { receivedData = data; };
    once("one-shot", cb);

    // on()에 전달된 래퍼 콜백을 가져와서 호출
    const wrapper = mockBridge.on.mock.calls[0][1] as Function;
    wrapper("test-data");

    expect(receivedData).toBe("test-data");
    expect(cancelCalled).toBe(true);
  });
});

describe("send", () => {
  it("calls bridge emit with JSON stringified data (no target → broadcast)", () => {
    send("click", { button: "save" });
    expect(mockBridge.emit).toHaveBeenCalledTimes(1);
    expect(mockBridge.emit).toHaveBeenCalledWith("click", '{"button":"save"}', undefined);
  });

  it("handles null data", () => {
    send("ping", null);
    expect(mockBridge.emit).toHaveBeenCalledWith("ping", "{}", undefined);
  });

  it("handles undefined data", () => {
    send("ping", undefined);
    expect(mockBridge.emit).toHaveBeenCalledWith("ping", "{}", undefined);
  });

  it("forwards {to: winId} as third argument (webContents.send)", () => {
    send("toast", { text: "saved" }, { to: 2 });
    expect(mockBridge.emit).toHaveBeenCalledWith("toast", '{"text":"saved"}', 2);
  });
});

describe("off", () => {
  it("calls bridge off", () => {
    off("test-event");
    expect(mockBridge.off).toHaveBeenCalledWith("test-event");
  });
});

describe("fanout", () => {
  it("joins backends and stringifies request", async () => {
    await fanout(["zig", "rust", "go"], "ping");
    expect(mockBridge.fanout).toHaveBeenCalledTimes(1);
    expect(mockBridge.fanout).toHaveBeenCalledWith("zig,rust,go", '{"cmd":"ping"}');
  });

  it("includes data in request", async () => {
    await fanout(["rust", "go"], "greet", { name: "Suji" });
    expect(mockBridge.fanout).toHaveBeenCalledWith("rust,go", '{"cmd":"greet","name":"Suji"}');
  });
});

describe("chain", () => {
  it("calls bridge chain with stringified request", async () => {
    await chain("rust", "go", "relay", { msg: "hello" });
    expect(mockBridge.chain).toHaveBeenCalledTimes(1);
    expect(mockBridge.chain).toHaveBeenCalledWith("rust", "go", '{"cmd":"relay","msg":"hello"}');
  });
});

describe("menu", () => {
  it("setApplicationMenu calls core with items", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    const ok = await menu.setApplicationMenu([
      { label: "Tools", submenu: [{ label: "Run", click: "run" }, { type: "checkbox", label: "Flag", click: "flag", checked: true }] },
    ]);
    expect(ok).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"menu_set_application_menu","items":[{"label":"Tools","submenu":[{"label":"Run","click":"run"},{"type":"checkbox","label":"Flag","click":"flag","checked":true}]}]}');
  });

  it("resetApplicationMenu calls core", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    await menu.resetApplicationMenu();
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"menu_reset_application_menu"}');
  });
});

describe("fs", () => {
  it("readFile calls core and returns text", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true, text: "hello" });
    const text = await sujiFs.readFile("/tmp/a.txt");
    expect(text).toBe("hello");
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"fs_read_file","path":"/tmp/a.txt"}');
  });

  it("writeFile / stat / mkdir / readdir call core", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await sujiFs.writeFile("/tmp/a.txt", "hello\nworld")).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"fs_write_file","path":"/tmp/a.txt","text":"hello\\nworld"}');

    mockBridge.core.mockResolvedValueOnce({ success: true, type: "file", size: 5, mtime: 1700000000000 });
    const st = await sujiFs.stat("/tmp/a.txt");
    expect(st.type).toBe("file");
    expect(st.size).toBe(5);
    // mtime은 ms (Date 호환) — 13자리 이하.
    expect(st.mtime).toBe(1700000000000);
    expect(String(st.mtime).length).toBeLessThanOrEqual(13);

    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await sujiFs.mkdir("/tmp/dir", { recursive: true })).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"fs_mkdir","path":"/tmp/dir","recursive":true}');

    mockBridge.core.mockResolvedValueOnce({ success: true, entries: [{ name: "a.txt", type: "file" }] });
    expect(await sujiFs.readdir("/tmp")).toEqual([{ name: "a.txt", type: "file" }]);

    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await sujiFs.rm("/tmp/x", { recursive: true, force: true })).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"fs_rm","path":"/tmp/x","recursive":true,"force":true}');
  });

  it("rm throws on failure", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false, error: "not_found" });
    await expect(sujiFs.rm("/tmp/x")).rejects.toThrow("not_found");
  });

  it("stat throws on failure", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false, error: "not_found" });
    await expect(sujiFs.stat("/missing")).rejects.toThrow("not_found");
  });
});

describe("globalShortcut", () => {
  it("register / unregister / unregisterAll / isRegistered call core", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await globalShortcut.register("Cmd+Shift+K", "openSettings")).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"global_shortcut_register","accelerator":"Cmd+Shift+K","click":"openSettings"}');

    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await globalShortcut.unregister("Cmd+Shift+K")).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"global_shortcut_unregister","accelerator":"Cmd+Shift+K"}');

    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await globalShortcut.unregisterAll()).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"global_shortcut_unregister_all"}');

    mockBridge.core.mockResolvedValueOnce({ registered: true });
    expect(await globalShortcut.isRegistered("Cmd+Q")).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"global_shortcut_is_registered","accelerator":"Cmd+Q"}');
  });

  it("register returns false on success:false", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false, error: "parse_failed" });
    expect(await globalShortcut.register("X", "y")).toBe(false);
  });

  it("register escapes JSON-special chars in accelerator/click", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    await globalShortcut.register('Cmd+"한글"', 'click\nwith\\ctrl');
    expect(mockBridge.core).toHaveBeenCalledWith(
      JSON.stringify({
        cmd: "global_shortcut_register",
        accelerator: 'Cmd+"한글"',
        click: 'click\nwith\\ctrl',
      }),
    );
  });
});

describe("error handling", () => {
  it("throws when bridge not available", async () => {
    const original = (window as any).__suji__;
    (window as any).__suji__ = undefined;

    try {
      await invoke("ping");
      expect(true).toBe(false); // should not reach
    } catch (e: any) {
      expect(e.message).toContain("Suji bridge not available");
    }

    (window as any).__suji__ = original;
  });
});

describe("shell.trashItem", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("sends shell_trash_item with path + maps success", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await shell.trashItem("/tmp/x")).toBe(true);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "shell_trash_item",
      path: "/tmp/x",
    });
  });

  it("returns false when success:false", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false });
    expect(await shell.trashItem("/missing")).toBe(false);
  });
});

describe("screen.getAllDisplays", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("calls screen_get_all_displays + returns displays array", async () => {
    mockBridge.core.mockResolvedValueOnce({ displays: [{ index: 0, isPrimary: true, x: 0, y: 0, width: 1920, height: 1080, visibleX: 0, visibleY: 0, visibleWidth: 1920, visibleHeight: 1055, scaleFactor: 2 }] });
    const r = await screen.getAllDisplays();
    expect(mockBridge.core).toHaveBeenCalledTimes(1);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0]).cmd).toBe("screen_get_all_displays");
    expect(r.length).toBe(1);
    expect(r[0].isPrimary).toBe(true);
    expect(r[0].scaleFactor).toBe(2);
  });
});

describe("powerSaveBlocker", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("start sends type + returns id", async () => {
    mockBridge.core.mockResolvedValueOnce({ id: 7 });
    const id = await powerSaveBlocker.start("prevent_display_sleep");
    const req = JSON.parse(mockBridge.core.mock.calls[0][0]);
    expect(req).toEqual({ cmd: "power_save_blocker_start", type: "prevent_display_sleep" });
    expect(id).toBe(7);
  });

  it("stop sends id + maps success to bool", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await powerSaveBlocker.stop(7)).toBe(true);
    mockBridge.core.mockResolvedValueOnce({ success: false });
    expect(await powerSaveBlocker.stop(0)).toBe(false);
  });
});

describe("safeStorage", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("setItem sends service/account/value", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await safeStorage.setItem("svc", "acc", "v")).toBe(true);
    const req = JSON.parse(mockBridge.core.mock.calls[0][0]);
    expect(req).toEqual({ cmd: "safe_storage_set", service: "svc", account: "acc", value: "v" });
  });

  it("getItem returns value field", async () => {
    mockBridge.core.mockResolvedValueOnce({ value: "secret" });
    expect(await safeStorage.getItem("svc", "acc")).toBe("secret");
  });

  it("deleteItem maps success", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await safeStorage.deleteItem("svc", "acc")).toBe(true);
  });
});

describe("app", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("getPath sends name + returns path", async () => {
    mockBridge.core.mockResolvedValueOnce({ path: "/Users/foo/Library/Application Support/MyApp" });
    const p = await app.getPath("userData");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "app_get_path", name: "userData" });
    expect(p).toContain("MyApp");
  });

  it("requestUserAttention default critical=true", async () => {
    mockBridge.core.mockResolvedValueOnce({ id: 42 });
    const id = await app.requestUserAttention();
    const req = JSON.parse(mockBridge.core.mock.calls[0][0]);
    expect(req).toEqual({ cmd: "app_attention_request", critical: true });
    expect(id).toBe(42);
  });

  it("requestUserAttention informational", async () => {
    mockBridge.core.mockResolvedValueOnce({ id: 1 });
    await app.requestUserAttention(false);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0]).critical).toBe(false);
  });

  it("cancelUserAttentionRequest maps success", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await app.cancelUserAttentionRequest(42)).toBe(true);
    mockBridge.core.mockResolvedValueOnce({ success: false });
    expect(await app.cancelUserAttentionRequest(0)).toBe(false);
  });

  it("dock.setBadge sends text", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    await app.dock.setBadge("99");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "dock_set_badge", text: "99" });
  });

  it("dock.getBadge returns text field", async () => {
    mockBridge.core.mockResolvedValueOnce({ text: "9" });
    expect(await app.dock.getBadge()).toBe("9");
  });
});
