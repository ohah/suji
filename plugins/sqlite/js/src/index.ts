/**
 * @suji/plugin-sqlite — SQLite Plugin for Suji Renderer
 *
 * Local DB (vendored SQLite 3.51). Parameterized via positional `?`
 * placeholders — pass values in `params`, never string-concatenate user
 * input into SQL (SQL injection-safe).
 *
 * ```ts
 * import { sqlite } from '@suji/plugin-sqlite';
 *
 * const db = await sqlite.open(':memory:');
 * await sqlite.execute(db, 'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
 * await sqlite.execute(db, 'INSERT INTO t(name) VALUES (?)', ['yoon']);
 * const rows = await sqlite.query(db, 'SELECT * FROM t WHERE name = ?', ['yoon']);
 * await sqlite.close(db);
 * ```
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

type SqlParam = string | number | boolean | null;

async function call(channel: string, data: Record<string, unknown>): Promise<any> {
  const resp = await getBridge().invoke(channel, data);
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
    if (typeof r?.dbId !== "number") {
      throw new Error("sqlite: malformed open response (no dbId)");
    }
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
    return (r?.rows ?? []) as T[];
  },

  /** Close a database handle. */
  async close(db: number): Promise<void> {
    await call("sql:close", { dbId: db });
  },
};
