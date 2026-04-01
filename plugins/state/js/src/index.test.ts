import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
  on: mock((_event: string, _cb: Function) => mock(() => {})),
  emit: mock(() => Promise.resolve()),
};

(globalThis as any).window = { __suji__: mockBridge };

const { state } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
  mockBridge.on.mockClear();
});

describe("state.get", () => {
  it("calls invoke with state:get", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: "yoon" } });
    const val = await state.get("user");
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:get", { key: "user" });
    expect(val).toBe("yoon");
  });

  it("returns null for missing key", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: null } });
    const val = await state.get("missing");
    expect(val).toBeNull();
  });
});

describe("state.set", () => {
  it("calls invoke with state:set", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.set("user", "yoon");
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:set", { key: "user", value: "yoon" });
  });

  it("supports number values", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.set("count", 42);
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:set", { key: "count", value: 42 });
  });

  it("supports object values", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.set("config", { theme: "dark" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:set", { key: "config", value: { theme: "dark" } });
  });
});

describe("state.delete", () => {
  it("calls invoke with state:delete", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.delete("user");
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:delete", { key: "user" });
  });
});

describe("state.keys", () => {
  it("returns array of keys", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { keys: ["a", "b", "c"] } });
    const keys = await state.keys();
    expect(keys).toEqual(["a", "b", "c"]);
  });

  it("returns empty array when no keys", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { keys: [] } });
    const keys = await state.keys();
    expect(keys).toEqual([]);
  });
});

describe("state.clear", () => {
  it("calls invoke with state:clear", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.clear();
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:clear");
  });
});

describe("state.watch", () => {
  it("subscribes to state:{key} event", () => {
    const cancel = state.watch("user", () => {});
    expect(mockBridge.on).toHaveBeenCalledTimes(1);
    const args = mockBridge.on.mock.calls[0];
    expect(args[0]).toBe("state:user");
    expect(typeof cancel).toBe("function");
  });
});
