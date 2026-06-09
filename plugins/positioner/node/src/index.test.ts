import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve('{"result":{}}')),
};

(globalThis as any).suji = mockBridge;

const { positioner } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

function lastCall(): { backend: string; payload: Record<string, unknown> } {
  const args = mockBridge.invoke.mock.calls.at(-1)!;
  return { backend: args[0] as string, payload: JSON.parse(args[1] as string) };
}

describe("positioner Node — routing + wire", () => {
  it("move routes to 'positioner' backend with cmd", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true,"x":5,"y":7}}');
    const r = await positioner.move("center", { windowId: 1 });
    const { backend, payload } = lastCall();
    expect(backend).toBe("positioner");
    expect(payload).toEqual({ cmd: "positioner:move", position: "center", windowId: 1 });
    expect(r).toEqual({ x: 5, y: 7 });
  });

  it("tray-center passes trayId", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true,"x":0,"y":0}}');
    await positioner.move("tray-center", { windowId: 2, trayId: 9 });
    expect(lastCall().payload).toEqual({ cmd: "positioner:move", position: "tray-center", windowId: 2, trayId: 9 });
  });

  it("omits undefined opts", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true,"x":1,"y":1}}');
    await positioner.move("bottom-right");
    expect(lastCall().payload).toEqual({ cmd: "positioner:move", position: "bottom-right" });
  });
});

describe("error propagation", () => {
  it("throws on bridge error", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"error":"no window"}');
    await expect(positioner.move("center", { windowId: 1 })).rejects.toThrow("positioner: no window");
  });
});
