/**
 * @suji/plugin-sqlite (renderer) 단위 테스트 — mock 브릿지로 와이어 계약 검증.
 *
 * 실행: `bun test plugins/sqlite/js/src/index.test.ts`
 *
 * renderer 브릿지는 `window.__suji__.invoke(channel, dataObj)` 형태로
 * 이미-파싱된 객체를 반환(백엔드의 backend+JSON 문자열과 다른 계층).
 * plugins/state/js 테스트 인프라 동형. backend 변형(plugins/sqlite/node)
 * 과 동일한 malformed 하드닝을 4언어 일관성으로 함께 검증.
 */
import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
};

(globalThis as any).window = { __suji__: mockBridge };

const { sqlite } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("sqlite.open", () => {
  it("invoke('sql:open', {path}) → dbId", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { dbId: 1 } });
    const db = await sqlite.open(":memory:");
    expect(mockBridge.invoke).toHaveBeenCalledWith("sql:open", { path: ":memory:" });
    expect(db).toBe(1);
  });

  it("throws on error envelope", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "unable to open" });
    await expect(sqlite.open("/bad")).rejects.toThrow(/sqlite: unable to open/);
  });
});

describe("sqlite.execute", () => {
  it("invoke('sql:execute', {dbId,sql,params}) → ExecResult", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { changes: 1, lastInsertRowid: 7 } });
    const r = await sqlite.execute(1, "INSERT INTO t(name) VALUES (?)", ["yoon"]);
    expect(mockBridge.invoke).toHaveBeenCalledWith("sql:execute", {
      dbId: 1,
      sql: "INSERT INTO t(name) VALUES (?)",
      params: ["yoon"],
    });
    expect(r).toEqual({ changes: 1, lastInsertRowid: 7 });
  });

  it("defaults params to []", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { changes: 0, lastInsertRowid: 0 } });
    await sqlite.execute(1, "CREATE TABLE t(id INTEGER)");
    expect(mockBridge.invoke).toHaveBeenCalledWith("sql:execute", {
      dbId: 1,
      sql: "CREATE TABLE t(id INTEGER)",
      params: [],
    });
  });
});

describe("sqlite.query", () => {
  it("returns rows array, forwards typed params", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { rows: [{ id: 1, name: "yoon" }] } });
    const rows = await sqlite.query(1, "SELECT * FROM t WHERE id > ? AND ok = ?", [0, true]);
    expect(mockBridge.invoke).toHaveBeenCalledWith("sql:query", {
      dbId: 1,
      sql: "SELECT * FROM t WHERE id > ? AND ok = ?",
      params: [0, true],
    });
    expect(rows).toEqual([{ id: 1, name: "yoon" }]);
  });

  it("returns [] when result has no rows", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    expect(await sqlite.query(1, "SELECT 1")).toEqual([]);
  });

  it("throws on error envelope", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "no such table: t" });
    await expect(sqlite.query(1, "SELECT * FROM t")).rejects.toThrow(/sqlite: no such table/);
  });
});

describe("sqlite.close", () => {
  it("invoke('sql:close', {dbId})", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await sqlite.close(1);
    expect(mockBridge.invoke).toHaveBeenCalledWith("sql:close", { dbId: 1 });
  });
});

describe("error envelope propagates on every method", () => {
  it.each([
    ["open", () => sqlite.open("/x")],
    ["execute", () => sqlite.execute(1, "X")],
    ["query", () => sqlite.query(1, "X")],
    ["close", () => sqlite.close(1)],
  ])("%s rejects on {error}", async (_label, op) => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "locked" });
    await expect(op()).rejects.toThrow(/sqlite: locked/);
  });
});

describe("malformed / empty response (non-error, no result) — node 변형과 동일 하드닝", () => {
  // open 은 dbId 를 날조 불가 → 명시적 throw(bare TypeError 아님).
  // query/close 는 graceful([] / no-op) — state.keys `?? []` 와 동형.
  it("open rejects with an explicit malformed error", async () => {
    mockBridge.invoke.mockResolvedValueOnce({});
    await expect(sqlite.open(":memory:")).rejects.toThrow(/sqlite: malformed open response/);
  });

  it("query degrades to [] when result is absent", async () => {
    mockBridge.invoke.mockResolvedValueOnce({});
    expect(await sqlite.query(1, "SELECT 1")).toEqual([]);
  });

  it("close tolerates a result-less response", async () => {
    mockBridge.invoke.mockResolvedValueOnce({});
    await expect(sqlite.close(1)).resolves.toBeUndefined();
  });
});

describe("bridge absent", () => {
  it("throws the renderer bridge error", async () => {
    const saved = (globalThis as any).window;
    (globalThis as any).window = {};
    try {
      await expect(sqlite.open(":memory:")).rejects.toThrow(/Suji bridge not available/);
    } finally {
      (globalThis as any).window = saved;
    }
  });
});
