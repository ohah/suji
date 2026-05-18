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
function getBridge() {
    const bridge = window.__suji__;
    if (!bridge)
        throw new Error("Suji bridge not available.");
    return bridge;
}
async function call(channel, data) {
    const resp = await getBridge().invoke(channel, data);
    if (resp?.error)
        throw new Error(`sqlite: ${resp.error}`);
    return resp?.result;
}
export const sqlite = {
    /**
     * Open (or create) a database. `":memory:"`, an absolute path, or a
     * relative path (resolved under the app-data `suji-app/sqlite/` dir).
     */
    async open(path) {
        const r = await call("sql:open", { path });
        if (typeof r?.dbId !== "number") {
            throw new Error("sqlite: malformed open response (no dbId)");
        }
        return r.dbId;
    },
    /** Run a non-SELECT statement (INSERT/UPDATE/DELETE/DDL). */
    async execute(db, sql, params = []) {
        return (await call("sql:execute", { dbId: db, sql, params }));
    },
    /** Run a SELECT; resolves to an array of row objects (column → value). */
    async query(db, sql, params = []) {
        const r = await call("sql:query", { dbId: db, sql, params });
        return (r?.rows ?? []);
    },
    /** Close a database handle. */
    async close(db) {
        await call("sql:close", { dbId: db });
    },
};
