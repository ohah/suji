import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve('{"result":{}}')),
};

(globalThis as any).suji = mockBridge;

const { windowState } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

function lastCall(): { backend: string; payload: Record<string, unknown> } {
  const args = mockBridge.invoke.mock.calls.at(-1)!;
  return { backend: args[0] as string, payload: JSON.parse(args[1] as string) };
}

describe("window-state Node — routing + wire", () => {
  it("saveState routes to 'window-state' backend with cmd", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await windowState.saveState({ key: "main", windowId: 1 });
    const { backend, payload } = lastCall();
    expect(backend).toBe("window-state");
    expect(payload).toEqual({ cmd: "window-state:save", key: "main", windowId: 1 });
  });

  it("restoreState returns restored bool", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true,"restored":true}}');
    expect(await windowState.restoreState({ key: "main", windowId: 1 })).toBe(true);
    expect(lastCall().payload).toEqual({ cmd: "window-state:restore", key: "main", windowId: 1 });
  });

  it("getState unwraps state, sends key only", async () => {
    const st = { x: 1, y: 2, width: 3, height: 4, maximized: true };
    mockBridge.invoke.mockResolvedValueOnce(JSON.stringify({ result: { state: st } }));
    expect(await windowState.getState({ key: "main" })).toEqual(st);
    expect(lastCall().payload).toEqual({ cmd: "window-state:get", key: "main" });
  });

  it("clearState sends key only", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await windowState.clearState({ key: "main" });
    expect(lastCall().payload).toEqual({ cmd: "window-state:clear", key: "main" });
  });

  it("empty opts → bare cmd", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true,"restored":false}}');
    await windowState.restoreState();
    expect(lastCall().payload).toEqual({ cmd: "window-state:restore" });
  });
});

describe("error propagation", () => {
  it("throws when bridge response has error", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"error":"no window"}');
    await expect(windowState.saveState({ windowId: 1 })).rejects.toThrow("window-state: no window");
  });
});
