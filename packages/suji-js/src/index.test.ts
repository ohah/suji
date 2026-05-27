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
const { invoke, on, once, send, off, fanout, chain, tray, menu, fs: sujiFs, globalShortcut, screen, desktopCapturer, powerSaveBlocker, safeStorage, app, shell, webRequest, crashReporter, autoUpdater, BrowserWindow, windows } = await import("./index");

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

describe("tray", () => {
  it("create forwards iconPath", async () => {
    mockBridge.core.mockResolvedValueOnce({ trayId: 7 });
    const result = await tray.create({ title: "App", tooltip: "tip", iconPath: "/tmp/tray.png" });
    expect(result.trayId).toBe(7);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"tray_create","title":"App","tooltip":"tip","iconPath":"/tmp/tray.png"}');
  });

  it("setMenu forwards submenu, checkbox, and enabled flags", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    const ok = await tray.setMenu(7, [
      { type: "checkbox", label: "Flag", click: "flag", checked: true, enabled: false },
      { label: "More", submenu: [{ label: "Child", click: "child" }] },
    ]);
    expect(ok).toBe(true);
    expect(mockBridge.core).toHaveBeenCalledWith('{"cmd":"tray_set_menu","trayId":7,"items":[{"type":"checkbox","label":"Flag","click":"flag","checked":true,"enabled":false},{"label":"More","submenu":[{"label":"Child","click":"child"}]}]}');
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

describe("webRequest.setBlockedUrls", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("sends patterns array + returns count", async () => {
    mockBridge.core.mockResolvedValueOnce({ count: 2 });
    const n = await webRequest.setBlockedUrls(["https://a/*", "https://b/*"]);
    expect(n).toBe(2);
    const req = JSON.parse(mockBridge.core.mock.calls[0][0]);
    expect(req.cmd).toBe("web_request_set_blocked_urls");
    expect(req.patterns).toEqual(["https://a/*", "https://b/*"]);
  });

  it("empty list clears patterns", async () => {
    mockBridge.core.mockResolvedValueOnce({ count: 0 });
    expect(await webRequest.setBlockedUrls([])).toBe(0);
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

describe("desktopCapturer", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("getSources sends desktop_capturer_get_sources + unwraps sources", async () => {
    mockBridge.core.mockResolvedValueOnce({ sources: [{ id: "screen:1:0", type: "screen" }] });
    const r = await desktopCapturer.getSources({ types: ["screen"] });
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "desktop_capturer_get_sources",
      types: "screen",
    });
    expect(r).toEqual([{ id: "screen:1:0", type: "screen" }]);
  });

  it("captureThumbnail sends sourceId/path + maps success", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false });
    expect(await desktopCapturer.captureThumbnail("bad-source", "/tmp/thumb.png")).toBe(false);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "desktop_capturer_capture_thumbnail",
      sourceId: "bad-source",
      path: "/tmp/thumb.png",
    });
  });
});

describe("crashReporter", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("start sends options and maps success", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await crashReporter.start({ uploadToServer: false, extra: { suite: "unit" } })).toBe(true);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "crash_reporter_start",
      uploadToServer: false,
      extra: { suite: "unit" },
    });
  });

  it("start maps core validation failure to false", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false, error: "submitURL_required" });
    expect(await crashReporter.start({ uploadToServer: true })).toBe(false);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "crash_reporter_start",
      uploadToServer: true,
    });
  });

  it("parameters and upload flag wrappers unwrap core responses", async () => {
    mockBridge.core.mockResolvedValueOnce({ parameters: { suite: "unit" } });
    expect(await crashReporter.getParameters()).toEqual({ suite: "unit" });

    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await crashReporter.addExtraParameter("mode", "test")).toBe(true);

    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await crashReporter.removeExtraParameter("mode")).toBe(true);

    mockBridge.core.mockResolvedValueOnce({ uploadToServer: false });
    expect(await crashReporter.getUploadToServer()).toBe(false);

    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await crashReporter.setUploadToServer(false)).toBe(true);
  });

  it("reports wrappers return empty/null defaults", async () => {
    mockBridge.core.mockResolvedValueOnce({ reports: [] });
    expect(await crashReporter.getUploadedReports()).toEqual([]);

    mockBridge.core.mockResolvedValueOnce({ report: null });
    expect(await crashReporter.getLastCrashReport()).toBeNull();
  });
});

describe("autoUpdater", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("checkForUpdates sends manifest fields and returns result", async () => {
    mockBridge.core.mockResolvedValueOnce({
      updateAvailable: true,
      currentVersion: "1.0.0",
      version: "1.1.0",
      url: "https://example.test/app.zip",
      sha256: "",
      notes: "release notes",
      pubDate: "2026-05-25T00:00:00Z",
    });
    const r = await autoUpdater.checkForUpdates(
      {
        version: "1.1.0",
        url: "https://example.test/app.zip",
        notes: "release notes",
        pubDate: "2026-05-25T00:00:00Z",
      },
      { currentVersion: "1.0.0" },
    );
    expect(r.updateAvailable).toBe(true);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "auto_updater_check_update",
      currentVersion: "1.0.0",
      latestVersion: "1.1.0",
      url: "https://example.test/app.zip",
      sha256: "",
      notes: "release notes",
      pubDate: "2026-05-25T00:00:00Z",
    });
  });

  it("verifyFile sends path/hash and returns actual digest", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false, actualSha256: "abc" });
    const r = await autoUpdater.verifyFile("/tmp/suji.zip", "0".repeat(64));
    expect(r).toEqual({ success: false, actualSha256: "abc" });
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "auto_updater_verify_file",
      path: "/tmp/suji.zip",
      sha256: "0".repeat(64),
    });
  });

  it("downloadArtifact sends URL/path/hash and supports manifest sha default", async () => {
    mockBridge.core.mockResolvedValueOnce({
      success: true,
      path: "/tmp/suji.zip",
      sha256: "1".repeat(64),
      size: 12,
    });
    const r = await autoUpdater.downloadArtifact(
      { version: "1.2.0", url: "https://example.test/suji.zip", sha256: "1".repeat(64) },
      "/tmp/suji.zip",
    );
    expect(r.success).toBe(true);
    expect(r.size).toBe(12);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "auto_updater_download_artifact",
      url: "https://example.test/suji.zip",
      path: "/tmp/suji.zip",
      sha256: "1".repeat(64),
    });
  });

  it("prepareInstall sends artifact, stage and format policy", async () => {
    mockBridge.core.mockResolvedValueOnce({
      success: true,
      path: "/tmp/Suji.app",
      source: "/tmp/Suji.app",
      target: "/Applications/Suji.app",
      stageDir: "/tmp/suji-stage",
      format: "zip",
      action: "quitAndInstall",
      requiresQuitAndInstall: true,
    });
    const r = await autoUpdater.prepareInstall(
      { success: true, path: "/tmp/suji.zip", sha256: "3".repeat(64), size: 12 },
      { target: "/Applications/Suji.app", stageDir: "/tmp/suji-stage", format: "zip" },
    );
    expect(r.requiresQuitAndInstall).toBe(true);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "auto_updater_prepare_install",
      path: "/tmp/suji.zip",
      target: "/Applications/Suji.app",
      stageDir: "/tmp/suji-stage",
      format: "zip",
      sha256: "3".repeat(64),
    });
  });

  it("quitAndInstall sends staged path, target, hash and relaunch policy", async () => {
    mockBridge.core.mockResolvedValueOnce({
      success: true,
      path: "/tmp/suji.zip",
      target: "/Applications/Suji.app",
      helperPath: "/tmp/suji.zip.quit-install.sh",
      relaunch: false,
    });
    const r = await autoUpdater.quitAndInstall(
      { success: true, path: "/tmp/suji.zip", sha256: "2".repeat(64), size: 12 },
      { target: "/Applications/Suji.app", relaunch: false },
    );
    expect(r.success).toBe(true);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "auto_updater_quit_and_install",
      path: "/tmp/suji.zip",
      target: "/Applications/Suji.app",
      sha256: "2".repeat(64),
      relaunch: false,
      helperPath: "",
    });
  });

  it("quitAndInstall reuses prepareInstall target when options.target is omitted", async () => {
    mockBridge.core.mockResolvedValueOnce({
      success: true,
      path: "/tmp/Suji.app",
      target: "/Applications/Suji.app",
      helperPath: "/tmp/Suji.app.quit-install.sh",
      relaunch: false,
    });
    await autoUpdater.quitAndInstall({
      success: true,
      path: "/tmp/Suji.app",
      source: "/tmp/Suji.app",
      target: "/Applications/Suji.app",
      stageDir: "/tmp/stage",
      format: "zip",
      action: "quitAndInstall",
      requiresQuitAndInstall: true,
    }, { relaunch: false });
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "auto_updater_quit_and_install",
      path: "/tmp/Suji.app",
      target: "/Applications/Suji.app",
      sha256: "",
      relaunch: false,
      helperPath: "",
    });
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

  it("setBadgeCount/getBadgeCount route through app badge count core commands", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    expect(await app.setBadgeCount(7)).toBe(true);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "app_set_badge_count", count: 7 });

    mockBridge.core.mockResolvedValueOnce({ count: 7 });
    expect(await app.getBadgeCount()).toBe(7);
    expect(JSON.parse(mockBridge.core.mock.calls[1][0])).toEqual({ cmd: "app_get_badge_count" });
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

describe("BrowserWindow (OO wrapper)", () => {
  beforeEach(() => mockBridge.core.mockClear());

  it("create() → 인스턴스, create_window 라우팅 + windowId 보유", async () => {
    mockBridge.core.mockResolvedValueOnce({ windowId: 7 });
    const win = await BrowserWindow.create({ title: "X" });
    expect(win).toBeInstanceOf(BrowserWindow);
    expect(win.id).toBe(7);
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "create_window", title: "X" });
  });

  it("fromId() + 인스턴스 메서드가 this.id로 windows.* 위임", async () => {
    const win = BrowserWindow.fromId(3);
    expect(win.id).toBe(3);
    mockBridge.core.mockResolvedValueOnce({ success: true });
    await win.setTitle("T");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "set_title", windowId: 3, title: "T" });
  });

  it("getter 위임 (getURL)", async () => {
    const win = BrowserWindow.fromId(5);
    mockBridge.core.mockResolvedValueOnce({ url: "http://x" });
    const r = await win.getURL();
    expect(r.url).toBe("http://x");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "get_url", windowId: 5 });
  });

  it("findInPage 옵션 패스스루", async () => {
    const win = BrowserWindow.fromId(2);
    mockBridge.core.mockResolvedValueOnce({ success: true });
    await win.findInPage("hi", { matchCase: true });
    const req = JSON.parse(mockBridge.core.mock.calls[0][0]);
    expect(req).toMatchObject({ cmd: "find_in_page", windowId: 2, text: "hi", matchCase: true });
  });
});

describe("windows.setUserAgent/getUserAgent", () => {
  beforeEach(() => mockBridge.core.mockClear());
  it("setUserAgent → set_user_agent 라우팅", async () => {
    mockBridge.core.mockResolvedValueOnce({ ok: true });
    await windows.setUserAgent(3, "Suji/1.0");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "set_user_agent", windowId: 3, userAgent: "Suji/1.0" });
  });
  it("getUserAgent → get_user_agent, userAgent 반환", async () => {
    mockBridge.core.mockResolvedValueOnce({ ok: true, userAgent: "Suji/1.0" });
    const r = await windows.getUserAgent(3);
    expect(r.userAgent).toBe("Suji/1.0");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "get_user_agent", windowId: 3 });
  });
  it("BrowserWindow.setUserAgent/getUserAgent 위임", async () => {
    const win = BrowserWindow.fromId(8);
    mockBridge.core.mockResolvedValueOnce({ ok: true });
    await win.setUserAgent("UA-X");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "set_user_agent", windowId: 8, userAgent: "UA-X" });
  });
});

describe("windows.capturePage (#16 deferred Promise)", () => {
  beforeEach(() => { mockBridge.core.mockClear(); mockBridge.on.mockClear(); });

  it("capture_page 라우팅 + coreCall 응답이 곧 결과 (no listener)", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    const r = await windows.capturePage(2, "/tmp/s.png");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "capture_page", windowId: 2, path: "/tmp/s.png" });
    expect(r).toEqual({ success: true });
    // listener pattern 제거 — on() 호출 없음
    expect(mockBridge.on).not.toHaveBeenCalled();
  });

  it("rect 지정 시 clipX/clipY/clipWidth/clipHeight 전송", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    await BrowserWindow.fromId(9).capturePage("/a.png", { x: 10, y: 20, width: 100, height: 50 });
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({
      cmd: "capture_page", windowId: 9, path: "/a.png",
      clipX: 10, clipY: 20, clipWidth: 100, clipHeight: 50,
    });
  });

  it("success:false 그대로 반환", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false });
    expect(await windows.capturePage(1, "/x.png")).toEqual({ success: false });
  });
});

describe("windows.printToPDF (#16 deferred Promise)", () => {
  beforeEach(() => { mockBridge.core.mockClear(); mockBridge.on.mockClear(); });

  it("print_to_pdf 라우팅 + 단일 await", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: true });
    const r = await windows.printToPDF(1, "/tmp/ok.pdf");
    expect(JSON.parse(mockBridge.core.mock.calls[0][0])).toEqual({ cmd: "print_to_pdf", windowId: 1, path: "/tmp/ok.pdf" });
    expect(r).toEqual({ success: true });
    expect(mockBridge.on).not.toHaveBeenCalled();
  });

  it("success:false 그대로 반환", async () => {
    mockBridge.core.mockResolvedValueOnce({ success: false });
    expect(await windows.printToPDF(1, "/bad.pdf")).toEqual({ success: false });
  });
});

describe("webRequest.onBeforeRequest timeout fallback", () => {
  const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

  // onBeforeRequest 등록 후 will-request 핸들러를 회수 + resolve(core) 호출 캡처.
  const setup = async (
    listener: (d: { url: string; id: number }, cb: (x: { cancel?: boolean }) => void) => void,
    opts?: { timeoutMs?: number },
  ) => {
    mockBridge.on.mockClear();
    mockBridge.core.mockClear();
    mockBridge.core.mockResolvedValue({ success: true });
    await webRequest.onBeforeRequest({ urls: ["*"] }, listener, opts);
    const call = mockBridge.on.mock.calls.find((c) => c[0] === "webRequest:will-request");
    const handler = call![1] as (payload: unknown) => void;
    return handler;
  };
  // bridge.core 로 간 web_request_resolve 호출만 추출 (filter set 호출 제외).
  const resolveCalls = () =>
    mockBridge.core.mock.calls
      .map((c) => JSON.parse(c[0] as string))
      .filter((r: any) => r.cmd === "web_request_resolve");

  it("decision callback → resolve 1회 + timer clear (이후 중복 없음)", async () => {
    const h = await setup((_d, cb) => cb({ cancel: true }), { timeoutMs: 20 });
    h(JSON.stringify({ url: "u", id: 7 }));
    await delay(60);
    const rs = resolveCalls();
    expect(rs).toEqual([{ cmd: "web_request_resolve", id: 7, cancel: true }]);
  });

  it("listener가 callback 미호출 → timeout 후 자동 통과(cancel:false) 1회", async () => {
    const h = await setup(() => {}, { timeoutMs: 20 });
    h(JSON.stringify({ url: "u", id: 9 }));
    expect(resolveCalls()).toEqual([]); // 즉시는 미해결
    await delay(60);
    expect(resolveCalls()).toEqual([{ cmd: "web_request_resolve", id: 9, cancel: false }]);
  });

  it("listener 동기 throw → 즉시 fail-open(cancel:false) 1회", async () => {
    const h = await setup(() => {
      throw new Error("boom");
    }, { timeoutMs: 20 });
    h(JSON.stringify({ url: "u", id: 11 }));
    expect(resolveCalls()).toEqual([{ cmd: "web_request_resolve", id: 11, cancel: false }]);
    await delay(60);
    expect(resolveCalls().length).toBe(1); // timer 가 중복 안 냄
  });

  it("decision 중복 호출 → settled 가드로 resolve 1회", async () => {
    const h = await setup((_d, cb) => {
      cb({ cancel: true });
      cb({});
    }, { timeoutMs: 20 });
    h(JSON.stringify({ url: "u", id: 13 }));
    await delay(40);
    expect(resolveCalls()).toEqual([{ cmd: "web_request_resolve", id: 13, cancel: true }]);
  });

  it("timeoutMs<=0 → 무제한(opt-out): 미응답이면 resolve 없음", async () => {
    const h = await setup(() => {}, { timeoutMs: 0 });
    h(JSON.stringify({ url: "u", id: 15 }));
    await delay(60);
    expect(resolveCalls()).toEqual([]);
  });

  it("malformed payload → throw 없이 무시(resolve 없음)", async () => {
    const h = await setup(() => {}, { timeoutMs: 20 });
    expect(() => h("{not-json")).not.toThrow();
    await delay(40);
    expect(resolveCalls()).toEqual([]);
  });
});
