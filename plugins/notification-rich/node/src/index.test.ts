import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve('{"result":{}}')),
};

(globalThis as any).suji = mockBridge;

const { richNotification } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

function lastPayload(): Record<string, unknown> {
  return JSON.parse(mockBridge.invoke.mock.calls.at(-1)![1] as string);
}

describe("richNotification Node — channel routing", () => {
  it("show: backend=notification-rich, cmd=notification:rich_show", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"id":3}}');
    const r = await richNotification.show({ title: "T", body: "B" });
    expect(r.id).toBe(3);
    const args = mockBridge.invoke.mock.calls.at(-1)!;
    expect(args[0]).toBe("notification-rich");
    expect(lastPayload()).toEqual({ cmd: "notification:rich_show", title: "T", body: "B" });
  });

  it("show: with options", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"id":9}}');
    await richNotification.show({
      title: "X",
      body: "Y",
      actions: [{ id: "a", label: "A" }],
      scenario: "alarm",
      silent: true,
    });
    expect(lastPayload()).toEqual({
      cmd: "notification:rich_show",
      title: "X",
      body: "Y",
      actions: [{ id: "a", label: "A" }],
      scenario: "alarm",
      silent: true,
    });
  });

  it("hide: cmd=notification:rich_hide", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await richNotification.hide(5);
    expect(lastPayload()).toEqual({ cmd: "notification:rich_hide", id: 5 });
  });

  it("error propagation", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"error":"unsupported_platform"}');
    await expect(richNotification.hide(1)).rejects.toThrow("notification-rich: unsupported_platform");
  });

  it("malformed JSON resp returns id=0", async () => {
    mockBridge.invoke.mockResolvedValueOnce("not json");
    const r = await richNotification.show({ title: "T", body: "B" });
    expect(r.id).toBe(0);
  });

  it("show passes image", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"id":1}}');
    await richNotification.show({ title: "T", body: "B", image: "C:/x.png" });
    expect(lastPayload()).toEqual({ cmd: "notification:rich_show", title: "T", body: "B", image: "C:/x.png" });
  });

  it("setImageRoots / getImageRoots round-trip", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await richNotification.setImageRoots(["C:/icons"]);
    expect(lastPayload()).toEqual({ cmd: "notification:set_image_roots", roots: ["C:/icons"] });

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"roots":["C:/icons"]}}');
    expect(await richNotification.getImageRoots()).toEqual(["C:/icons"]);
  });
});
