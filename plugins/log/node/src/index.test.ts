import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve('{"result":{}}')),
};

(globalThis as any).suji = mockBridge;

const { log } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

function lastCmd(): { cmd: string; payload: Record<string, unknown> } {
  const args = mockBridge.invoke.mock.calls.at(-1)!;
  return { cmd: args[0] as string, payload: JSON.parse(args[1] as string) };
}

describe("log.<level> Node wrapper", () => {
  it("info calls log backend with cmd=log:write", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await log.info("hello");
    const { cmd, payload } = lastCmd();
    expect(cmd).toBe("log");
    expect(payload).toEqual({ cmd: "log:write", level: "info", message: "hello" });
  });

  it("error includes context", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await log.error("oops", { user: "yoon" });
    expect(lastCmd().payload).toEqual({
      cmd: "log:write",
      level: "error",
      message: "oops",
      context: { user: "yoon" },
    });
  });

  it.each(["trace", "debug", "info", "warn", "error"] as const)("%s routes to log:write", async (lv) => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await (log as any)[lv]("m");
    expect(lastCmd().payload.level).toBe(lv);
  });
});

describe("log.setLevel / getLevel / read / set+getPath", () => {
  it("setLevel → cmd=log:set_level", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true,"level":"warn"}}');
    await log.setLevel("warn");
    expect(lastCmd().payload).toEqual({ cmd: "log:set_level", level: "warn" });
  });

  it("getLevel returns result.level", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"level":"debug"}}');
    const lv = await log.getLevel();
    expect(lv).toBe("debug");
    expect(lastCmd().payload).toEqual({ cmd: "log:get_level" });
  });

  it("read returns entries", async () => {
    mockBridge.invoke.mockResolvedValueOnce(
      '{"result":{"entries":[{"ts":1,"level":"info","message":"a"}]}}',
    );
    const r = await log.read(30);
    expect(r).toHaveLength(1);
    expect(r[0].message).toBe("a");
    expect(lastCmd().payload).toEqual({ cmd: "log:read", lines: "30" });
  });

  it("setPath / getPath round-trip", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true,"path":"/x/y.log"}}');
    expect(await log.setPath("/x/y.log")).toBe("/x/y.log");
    expect(lastCmd().payload).toEqual({ cmd: "log:set_path", path: "/x/y.log" });
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"path":"/x/y.log"}}');
    expect(await log.getPath()).toBe("/x/y.log");
    expect(lastCmd().payload).toEqual({ cmd: "log:get_path" });
  });
});

describe("error propagation", () => {
  it("rejects when raw JSON has error", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"error":"invalid level"}');
    await expect(log.setLevel("info")).rejects.toThrow("log: invalid level");
  });

  it("handles malformed JSON gracefully (resp = {})", async () => {
    mockBridge.invoke.mockResolvedValueOnce("not json");
    // resp = {} → no error → no throw, returns undefined
    await log.info("m");
  });
});
