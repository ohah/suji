import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
};

(globalThis as any).window = { __suji__: mockBridge };

const { createStore, store } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("createStore default name", () => {
  it("uses 'config' when name omitted", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: "v" } });
    await s.get("k");
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:get", { name: "config", key: "k" });
  });

  it("default singleton uses 'config'", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: 1 } });
    await store.get("anything");
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:get", { name: "config", key: "anything" });
  });
});

describe("createStore named", () => {
  it("passes name through all calls", async () => {
    const s = createStore("settings");
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: "dark" } });
    expect(await s.get("theme")).toBe("dark");
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:get", { name: "settings", key: "theme" });

    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await s.set("theme", "light");
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:set", { name: "settings", key: "theme", value: "light" });

    mockBridge.invoke.mockResolvedValueOnce({ result: { has: true } });
    expect(await s.has("theme")).toBe(true);
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:has", { name: "settings", key: "theme" });

    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await s.delete("theme");
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:delete", { name: "settings", key: "theme" });

    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await s.clear();
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:clear", { name: "settings" });

    mockBridge.invoke.mockResolvedValueOnce({ result: { keys: ["a", "b"] } });
    expect(await s.keys()).toEqual(["a", "b"]);
    expect(mockBridge.invoke).toHaveBeenCalledWith("store:keys", { name: "settings" });

    mockBridge.invoke.mockResolvedValueOnce({ result: { size: 7 } });
    expect(await s.size()).toBe(7);

    mockBridge.invoke.mockResolvedValueOnce({ result: { path: "/x.json" } });
    expect(await s.getPath()).toBe("/x.json");
  });
});

describe("store.get response unwrap", () => {
  it("returns null when value is null", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: null } });
    expect(await s.get("missing")).toBeNull();
  });

  it("returns null when value missing", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    expect(await s.get("missing")).toBeNull();
  });

  it("returns object value", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce({ result: { value: { x: 1 } } });
    expect(await s.get<{ x: number }>("k")).toEqual({ x: 1 });
  });
});

describe("error propagation", () => {
  it("throws when bridge response has error", async () => {
    const s = createStore("bad-name");
    mockBridge.invoke.mockResolvedValueOnce({ error: "invalid name" });
    await expect(s.get("k")).rejects.toThrow("store: invalid name");
  });
});

describe("size / has fallbacks", () => {
  it("size returns 0 when result missing", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    expect(await s.size()).toBe(0);
  });

  it("has returns false when result missing", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    expect(await s.has("k")).toBe(false);
  });
});
