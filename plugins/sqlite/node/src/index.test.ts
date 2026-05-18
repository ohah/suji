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
