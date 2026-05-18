/**
 * @suji/plugin-sqlite-node — SQLite Plugin for Suji Node.js backends
 *
 * Local DB (vendored SQLite 3.51). The backend counterpart of the renderer
 * `@suji/plugin-sqlite` — same wire contract as the Rust
 * (`suji-plugin-sqlite`) / Go (`suji-plugin-sqlite`) wrappers: route through
 * the `sqlite` backend with the cmd embedded in the request JSON.
 *
 * Parameterized via positional `?` placeholders — pass values in `params`,
 * never string-concatenate user input into SQL (SQL injection-safe).
 *
 * ```ts
 * const { sqlite } = require('@suji/plugin-sqlite-node');
 *
 * const db = await sqlite.open(':memory:');
 * await sqlite.execute(db, 'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
 * await sqlite.execute(db, 'INSERT INTO t(name) VALUES (?)', ['yoon']);
 * const rows = await sqlite.query(db, 'SELECT * FROM t WHERE name = ?', ['yoon']);
 * await sqlite.close(db);
 * ```
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-sqlite-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

type SqlParam = string | number | boolean | null;

/** invoke("sqlite", {cmd,...}) → 파싱 후 {from:"zig",result|error} 언랩 (Rust/Go 래퍼 동형). */
async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("sqlite", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`sqlite: ${resp.error}`);
  return resp?.result;
}

export interface ExecResult {
  changes: number;
  lastInsertRowid: number;
}

export const sqlite = {
  /**
   * Open (or create) a database. `":memory:"`, an absolute path, or a
   * relative path (resolved under the app-data `suji-app/sqlite/` dir).
   */
  async open(path: string): Promise<number> {
    const r = await call("sql:open", { path });
    return r.dbId as number;
  },

  /** Run a non-SELECT statement (INSERT/UPDATE/DELETE/DDL). */
  async execute(db: number, sql: string, params: SqlParam[] = []): Promise<ExecResult> {
    return (await call("sql:execute", { dbId: db, sql, params })) as ExecResult;
  },

  /** Run a SELECT; resolves to an array of row objects (column → value). */
  async query<T = Record<string, unknown>>(
    db: number,
    sql: string,
    params: SqlParam[] = [],
  ): Promise<T[]> {
    const r = await call("sql:query", { dbId: db, sql, params });
    return (r.rows ?? []) as T[];
  },

  /** Close a database handle. */
  async close(db: number): Promise<void> {
    await call("sql:close", { dbId: db });
  },
};
