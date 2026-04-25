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
  it("calls invoke with state:clear (no scope = clear all)", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.clear();
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:clear", {});
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

// ============================================
// Phase 2.5: scope 옵션
// ============================================

describe("state.* with scope option", () => {
  it("get with scope passes scope param", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: "split" } });
    await state.get("layout", { scope: "window" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:get", { key: "layout", scope: "window" });
  });

  it("set with scope passes scope param", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.set("layout", "split", { scope: "window:2" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:set", {
      key: "layout",
      value: "split",
      scope: "window:2",
    });
  });

  it("delete with scope passes scope param", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.delete("layout", { scope: "window" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:delete", {
      key: "layout",
      scope: "window",
    });
  });

  it("keys with scope passes scope param only", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { keys: ["a"] } });
    await state.keys({ scope: "session:onboard" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:keys", { scope: "session:onboard" });
  });

  it("clear with scope passes scope param", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await state.clear({ scope: "window:5" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("state:clear", { scope: "window:5" });
  });

  it("watch with scope=window:N uses state:window:N:{key} channel", () => {
    state.watch("layout", () => {}, { scope: "window:3" });
    expect(mockBridge.on).toHaveBeenCalledTimes(1);
    expect(mockBridge.on.mock.calls[0][0]).toBe("state:window:3:layout");
  });

  it("watch with scope=global falls back to legacy state:{key} channel", () => {
    state.watch("user", () => {}, { scope: "global" });
    expect(mockBridge.on).toHaveBeenCalledWith("state:user", expect.anything());
  });

  it("watch with scope=session uses state:<scope>:{key}", () => {
    state.watch("step", () => {}, { scope: "session:onboard" });
    expect(mockBridge.on).toHaveBeenCalledWith("state:session:onboard:step", expect.anything());
  });
});
