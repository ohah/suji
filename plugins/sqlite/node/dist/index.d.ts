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
type SqlParam = string | number | boolean | null;
export interface ExecResult {
    changes: number;
    lastInsertRowid: number;
}
export declare const sqlite: {
    /**
     * Open (or create) a database. `":memory:"`, an absolute path, or a
     * relative path (resolved under the app-data `suji-app/sqlite/` dir).
     */
    open(path: string): Promise<number>;
    /** Run a non-SELECT statement (INSERT/UPDATE/DELETE/DDL). */
    execute(db: number, sql: string, params?: SqlParam[]): Promise<ExecResult>;
    /** Run a SELECT; resolves to an array of row objects (column → value). */
    query<T = Record<string, unknown>>(db: number, sql: string, params?: SqlParam[]): Promise<T[]>;
    /** Close a database handle. */
    close(db: number): Promise<void>;
};
export {};
