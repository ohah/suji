import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve('{"result":{}}')),
};

(globalThis as any).suji = mockBridge;

const { createStore, store } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

function lastPayload(): Record<string, unknown> {
  const args = mockBridge.invoke.mock.calls.at(-1)!;
  return JSON.parse(args[1] as string);
}

describe("createStore Node — name default + routing", () => {
  it("default name='config'", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"value":"v"}}');
    await s.get("k");
    expect(lastPayload()).toEqual({ cmd: "store:get", name: "config", key: "k" });
  });

  it("named instance", async () => {
    const s = createStore("settings");
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"value":1}}');
    await s.get("k");
    expect(lastPayload()).toEqual({ cmd: "store:get", name: "settings", key: "k" });
  });

  it("set / has / delete / clear / keys / size / getPath all routed", async () => {
    const s = createStore("test");
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await s.set("k", { x: 1 });
    expect(lastPayload()).toEqual({ cmd: "store:set", name: "test", key: "k", value: { x: 1 } });

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"has":true}}');
    expect(await s.has("k")).toBe(true);
    expect(lastPayload()).toEqual({ cmd: "store:has", name: "test", key: "k" });

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await s.delete("k");
    expect(lastPayload()).toEqual({ cmd: "store:delete", name: "test", key: "k" });

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await s.clear();
    expect(lastPayload()).toEqual({ cmd: "store:clear", name: "test" });

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"keys":["a"]}}');
    expect(await s.keys()).toEqual(["a"]);

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"size":3}}');
    expect(await s.size()).toBe(3);

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"path":"/p"}}');
    expect(await s.getPath()).toBe("/p");
  });
});

describe("store singleton uses config", () => {
  it("uses 'config' name", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"value":1}}');
    await store.get("k");
    expect(lastPayload().name).toBe("config");
  });
});

describe("error propagation", () => {
  it("throws on response.error", async () => {
    const s = createStore("bad");
    mockBridge.invoke.mockResolvedValueOnce('{"error":"invalid name"}');
    await expect(s.get("k")).rejects.toThrow("store: invalid name");
  });

  it("handles malformed JSON (resp={})", async () => {
    const s = createStore();
    mockBridge.invoke.mockResolvedValueOnce("not json");
    expect(await s.get("k")).toBeNull();
  });
});
