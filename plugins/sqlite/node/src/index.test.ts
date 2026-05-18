/**
 * @suji/plugin-sqlite-node 단위 테스트 — mock 브릿지로 와이어 계약 검증.
 *
 * 실행: `bun test plugins/sqlite/node/src/index.test.ts`
 *
 * Node 백엔드는 libnode 임베디드라 dylib 로드 불가 → Rust/Go 처럼
 * BackendRegistry 하니스를 못 쓴다. 대신 `globalThis.suji` 브릿지를
 * mock 해 invoke("sqlite", {cmd,...}) 요청 형태와 응답/에러 언랩을
 * 검증 (plugins/sqlite/js 테스트 동형).
 *
 * 요청은 raw 문자열이 아니라 parse 후 구조 비교 — JSON 키 순서는
 * Zig 백엔드(필드명 파싱)에 무의미하므로 순서에 결합하지 않는다.
 */
import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock((_backend: string, _request: string) => Promise.resolve("{}")),
};

(globalThis as any).suji = mockBridge;

const { sqlite } = await import("./index");

const reply = (obj: unknown) => Promise.resolve(JSON.stringify({ from: "zig", ...(obj as object) }));

/** 마지막 invoke 호출의 backend + parse 한 요청 body (키 순서 무관). */
const lastReq = () => {
  const c = mockBridge.invoke.mock.calls.at(-1)!;
  return { backend: c[0], body: JSON.parse(c[1] as string) };
};

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("sqlite.open", () => {
  it("invoke('sqlite', {cmd:'sql:open',path}) → dbId", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { dbId: 1 } }));
    const db = await sqlite.open(":memory:");
    expect(lastReq()).toEqual({
      backend: "sqlite",
      body: { cmd: "sql:open", path: ":memory:" },
    });
    expect(db).toBe(1);
  });

  it("throws on error envelope", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ error: "unable to open" }));
    await expect(sqlite.open("/bad/path")).rejects.toThrow(/sqlite: unable to open/);
  });
});

describe("sqlite.execute", () => {
  it("invoke with dbId/sql/params, returns ExecResult", async () => {
    mockBridge.invoke.mockReturnValueOnce(
      reply({ result: { changes: 1, lastInsertRowid: 7 } }),
    );
    const r = await sqlite.execute(1, "INSERT INTO t(name) VALUES (?)", ["yoon"]);
    expect(lastReq()).toEqual({
      backend: "sqlite",
      body: {
        cmd: "sql:execute",
        dbId: 1,
        sql: "INSERT INTO t(name) VALUES (?)",
        params: ["yoon"],
      },
    });
    expect(r).toEqual({ changes: 1, lastInsertRowid: 7 });
  });

  it("defaults params to []", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { changes: 0, lastInsertRowid: 0 } }));
    await sqlite.execute(1, "CREATE TABLE t(id INTEGER)");
    expect(lastReq()).toEqual({
      backend: "sqlite",
      body: { cmd: "sql:execute", dbId: 1, sql: "CREATE TABLE t(id INTEGER)", params: [] },
    });
  });
});

describe("sqlite.query", () => {
  it("returns rows array", async () => {
    mockBridge.invoke.mockReturnValueOnce(
      reply({ result: { rows: [{ id: 1, name: "yoon" }] } }),
    );
    const rows = await sqlite.query(1, "SELECT * FROM t WHERE name = ?", ["yoon"]);
    expect(lastReq()).toEqual({
      backend: "sqlite",
      body: {
        cmd: "sql:query",
        dbId: 1,
        sql: "SELECT * FROM t WHERE name = ?",
        params: ["yoon"],
      },
    });
    expect(rows).toEqual([{ id: 1, name: "yoon" }]);
  });

  it("returns [] when result has no rows", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: {} }));
    expect(await sqlite.query(1, "SELECT 1")).toEqual([]);
  });

  it("throws on error envelope", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ error: "no such table: t" }));
    await expect(sqlite.query(1, "SELECT * FROM t")).rejects.toThrow(/sqlite: no such table/);
  });
});

describe("sqlite.close", () => {
  it("invoke('sqlite', {cmd:'sql:close',dbId})", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await sqlite.close(1);
    expect(lastReq()).toEqual({
      backend: "sqlite",
      body: { cmd: "sql:close", dbId: 1 },
    });
  });
});

// ============================================
// 복잡 경계 — 파라미터 타입 보존 / 전 메서드 에러 전파 /
//             malformed 응답 sharp edge / 브릿지 부재
// ============================================

describe("param type fidelity (positional ? binding)", () => {
  it("preserves mixed string/number/boolean/null params verbatim", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { changes: 1, lastInsertRowid: 9 } }));
    const params = ["s", 42, true, null];
    await sqlite.execute(3, "INSERT INTO t(a,b,c,d) VALUES (?,?,?,?)", params);
    expect(lastReq()).toEqual({
      backend: "sqlite",
      body: { cmd: "sql:execute", dbId: 3, sql: "INSERT INTO t(a,b,c,d) VALUES (?,?,?,?)", params },
    });
  });

  it("query forwards typed params and returns multi-row result", async () => {
    const rows = [
      { id: 1, n: "a", ok: 1 },
      { id: 2, n: "b", ok: 0 },
    ];
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { rows } }));
    const out = await sqlite.query(7, "SELECT * FROM t WHERE id > ? AND ok = ?", [0, true]);
    expect(lastReq().body.params).toEqual([0, true]);
    expect(out).toEqual(rows);
  });
});

describe("error envelope propagates on every method", () => {
  it.each([
    ["open", () => sqlite.open("/x")],
    ["execute", () => sqlite.execute(1, "X")],
    ["query", () => sqlite.query(1, "X")],
    ["close", () => sqlite.close(1)],
  ])("%s rejects on {error}", async (_label, op) => {
    mockBridge.invoke.mockReturnValueOnce(reply({ error: "locked" }));
    await expect(op()).rejects.toThrow(/sqlite: locked/);
  });
});

describe("execute result passthrough", () => {
  it("returns zero changes/rowid for DDL verbatim", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { changes: 0, lastInsertRowid: 0 } }));
    expect(await sqlite.execute(1, "CREATE TABLE t(id INTEGER)")).toEqual({
      changes: 0,
      lastInsertRowid: 0,
    });
  });
});

describe("malformed / empty response (non-error, no result)", () => {
  // A response that is neither a valid {result} nor {error} envelope is a
  // protocol violation. `open` needs a dbId it cannot fabricate → explicit
  // throw. `query`/`close` degrade gracefully ([] / no-op) for internal
  // consistency with state.keys' `r?.keys ?? []` (and Rust's graceful None).
  it("open rejects with an explicit malformed error (not a bare TypeError)", async () => {
    mockBridge.invoke.mockReturnValueOnce(Promise.resolve("garbage"));
    await expect(sqlite.open(":memory:")).rejects.toThrow(/sqlite: malformed open response/);
  });

  it("query degrades to [] when response carries neither result nor error", async () => {
    mockBridge.invoke.mockReturnValueOnce(Promise.resolve(""));
    expect(await sqlite.query(1, "SELECT 1")).toEqual([]);
  });

  it("close tolerates an empty response (no result access)", async () => {
    mockBridge.invoke.mockReturnValueOnce(Promise.resolve(""));
    await expect(sqlite.close(1)).resolves.toBeUndefined();
  });
});

describe("bridge absent", () => {
  it("throws a sqlite-node-scoped error", async () => {
    const saved = (globalThis as any).suji;
    (globalThis as any).suji = undefined;
    try {
      await expect(sqlite.open(":memory:")).rejects.toThrow(
        /@suji\/plugin-sqlite-node: bridge not available/,
      );
    } finally {
      (globalThis as any).suji = saved;
    }
  });
});

describe("sequential ops on one handle issue independent invokes", () => {
  it("open → execute → query → close = 4 distinct backend calls", async () => {
    mockBridge.invoke
      .mockReturnValueOnce(reply({ result: { dbId: 5 } }))
      .mockReturnValueOnce(reply({ result: { changes: 1, lastInsertRowid: 1 } }))
      .mockReturnValueOnce(reply({ result: { rows: [{ id: 1 }] } }))
      .mockReturnValueOnce(reply({ result: { ok: true } }));
    const db = await sqlite.open(":memory:");
    await sqlite.execute(db, "INSERT INTO t(id) VALUES (?)", [1]);
    const rows = await sqlite.query(db, "SELECT id FROM t");
    await sqlite.close(db);
    expect(mockBridge.invoke).toHaveBeenCalledTimes(4);
    expect(rows).toEqual([{ id: 1 }]);
    expect(mockBridge.invoke.mock.calls.every(([b]) => b === "sqlite")).toBe(true);
  });
});
