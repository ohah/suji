import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
};

(globalThis as any).window = { __suji__: mockBridge };

const { richNotification } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("richNotification.show — channel + payload shape", () => {
  it("minimal payload (title + body)", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { id: 7 } });
    const r = await richNotification.show({ title: "T", body: "B" });
    expect(r.id).toBe(7);
    expect(mockBridge.invoke).toHaveBeenCalledWith("notification:rich_show", { title: "T", body: "B" });
  });

  it("with actions / scenario / silent", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { id: 12 } });
    await richNotification.show({
      title: "Q",
      body: "Pick one",
      actions: [{ id: "yes", label: "Yes" }, { id: "no", label: "No" }],
      scenario: "reminder",
      silent: true,
    });
    expect(mockBridge.invoke).toHaveBeenCalledWith("notification:rich_show", {
      title: "Q",
      body: "Pick one",
      actions: [{ id: "yes", label: "Yes" }, { id: "no", label: "No" }],
      scenario: "reminder",
      silent: true,
    });
  });

  it("response defaults: missing id → 0", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    const r = await richNotification.show({ title: "T", body: "B" });
    expect(r.id).toBe(0);
  });
});

describe("richNotification.hide", () => {
  it("passes id", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await richNotification.hide(42);
    expect(mockBridge.invoke).toHaveBeenCalledWith("notification:rich_hide", { id: 42 });
  });
});

describe("error propagation", () => {
  it("throws when bridge errors", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "unsupported_platform" });
    await expect(richNotification.show({ title: "T", body: "B" })).rejects.toThrow(
      "notification-rich: unsupported_platform",
    );
  });
});
