import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
};

(globalThis as any).window = { __suji__: mockBridge };

const { windowState } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("saveState wire", () => {
  it("no opts → empty payload", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await windowState.saveState();
    expect(mockBridge.invoke).toHaveBeenCalledWith("window-state:save", {});
  });

  it("key + windowId pass through", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await windowState.saveState({ key: "settings", windowId: 3 });
    expect(mockBridge.invoke).toHaveBeenCalledWith("window-state:save", { key: "settings", windowId: 3 });
  });
});

describe("restoreState wire + return", () => {
  it("returns restored bool", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true, restored: true } });
    expect(await windowState.restoreState({ key: "main" })).toBe(true);
    expect(mockBridge.invoke).toHaveBeenCalledWith("window-state:restore", { key: "main" });
  });

  it("returns false when nothing stored", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true, restored: false } });
    expect(await windowState.restoreState()).toBe(false);
  });
});

describe("getState response unwrap", () => {
  it("returns state object", async () => {
    const st = { x: 10, y: 20, width: 800, height: 600, maximized: false };
    mockBridge.invoke.mockResolvedValueOnce({ result: { state: st } });
    expect(await windowState.getState({ key: "main" })).toEqual(st);
    // get 은 windowId 를 안 보냄
    expect(mockBridge.invoke).toHaveBeenCalledWith("window-state:get", { key: "main" });
  });

  it("returns null when state null", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { state: null } });
    expect(await windowState.getState()).toBeNull();
  });
});

describe("clearState wire", () => {
  it("sends key only", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await windowState.clearState({ key: "settings" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("window-state:clear", { key: "settings" });
  });
});

describe("error propagation", () => {
  it("throws when bridge response has error", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "no window" });
    await expect(windowState.saveState()).rejects.toThrow("window-state: no window");
  });
});
