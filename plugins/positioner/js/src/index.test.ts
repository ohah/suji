import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
};

(globalThis as any).window = { __suji__: mockBridge };

const { positioner } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("positioner.move wire", () => {
  it("position only", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true, x: 10, y: 20 } });
    const r = await positioner.move("center");
    expect(mockBridge.invoke).toHaveBeenCalledWith("positioner:move", { position: "center" });
    expect(r).toEqual({ x: 10, y: 20 });
  });

  it("passes windowId + trayId through", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true, x: 0, y: 0 } });
    await positioner.move("tray-center", { windowId: 2, trayId: 5 });
    expect(mockBridge.invoke).toHaveBeenCalledWith("positioner:move", {
      position: "tray-center",
      windowId: 2,
      trayId: 5,
    });
  });

  it("omits undefined opts", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true, x: 1, y: 2 } });
    await positioner.move("at-cursor", { windowId: 3 });
    expect(mockBridge.invoke).toHaveBeenCalledWith("positioner:move", { position: "at-cursor", windowId: 3 });
  });

  it("returns {0,0} when coords missing", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    expect(await positioner.move("center")).toEqual({ x: 0, y: 0 });
  });
});

describe("error propagation", () => {
  it("throws on bridge error", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "unknown position" });
    await expect(positioner.move("center")).rejects.toThrow("positioner: unknown position");
  });
});
