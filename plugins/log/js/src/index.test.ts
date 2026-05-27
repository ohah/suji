import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
};

(globalThis as any).window = { __suji__: mockBridge };

const { log } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("log.<level>", () => {
  it("info calls log:write with level + message", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await log.info("hello");
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:write", { level: "info", message: "hello" });
  });

  it("error calls log:write with context when provided", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await log.error("oops", { user: "yoon" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:write", {
      level: "error",
      message: "oops",
      context: { user: "yoon" },
    });
  });

  it.each(["trace", "debug", "info", "warn", "error"] as const)("%s routes to log:write", async (lv) => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await (log as any)[lv]("m");
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:write", { level: lv, message: "m" });
  });

  it("undefined context omits the field (not key with undefined value)", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await log.info("m", undefined);
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:write", { level: "info", message: "m" });
  });
});

describe("log.setLevel / getLevel", () => {
  it("setLevel calls log:set_level", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true, level: "warn" } });
    await log.setLevel("warn");
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:set_level", { level: "warn" });
  });

  it("getLevel returns response.level", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { level: "debug" } });
    const lv = await log.getLevel();
    expect(lv).toBe("debug");
  });

  it("getLevel defaults to 'info' when response missing level", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    const lv = await log.getLevel();
    expect(lv).toBe("info");
  });
});

describe("log.read", () => {
  it("requests N lines as string and returns entries", async () => {
    mockBridge.invoke.mockResolvedValueOnce({
      result: {
        entries: [
          { ts: 1, level: "info", message: "a" },
          { ts: 2, level: "warn", message: "b" },
        ],
      },
    });
    const r = await log.read(50);
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:read", { lines: "50" });
    expect(r).toHaveLength(2);
    expect(r[0].level).toBe("info");
  });

  it("defaults to 100 lines", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { entries: [] } });
    await log.read();
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:read", { lines: "100" });
  });

  it("returns [] when entries missing", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    const r = await log.read(10);
    expect(r).toEqual([]);
  });
});

describe("log.setPath / getPath", () => {
  it("setPath calls log:set_path", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true, path: "/x/y.log" } });
    const p = await log.setPath("/x/y.log");
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:set_path", { path: "/x/y.log" });
    expect(p).toBe("/x/y.log");
  });

  it("getPath calls log:get_path", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { path: "/x/y.log" } });
    const p = await log.getPath();
    expect(mockBridge.invoke).toHaveBeenCalledWith("log:get_path", {});
    expect(p).toBe("/x/y.log");
  });
});

describe("error propagation", () => {
  it("throws when response carries error", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "invalid level" });
    await expect(log.setLevel("info")).rejects.toThrow("log: invalid level");
  });
});
