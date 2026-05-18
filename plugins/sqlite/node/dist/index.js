"use strict";
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.sqlite = void 0;
function getBridge() {
    const bridge = globalThis.suji;
    if (!bridge) {
        throw new Error("@suji/plugin-sqlite-node: bridge not available. This module must run inside a Suji app (libnode embedding).");
    }
    return bridge;
}
/** invoke("sqlite", {cmd,...}) → 파싱 후 {from:"zig",result|error} 언랩 (Rust/Go 래퍼 동형). */
async function call(cmd, payload) {
    const raw = await getBridge().invoke("sqlite", JSON.stringify({ cmd, ...payload }));
    let resp;
    try {
        resp = JSON.parse(raw);
    }
    catch {
        resp = {};
    }
    if (resp?.error)
        throw new Error(`sqlite: ${resp.error}`);
    return resp?.result;
}
exports.sqlite = {
    /**
     * Open (or create) a database. `":memory:"`, an absolute path, or a
     * relative path (resolved under the app-data `suji-app/sqlite/` dir).
     */
    async open(path) {
        const r = await call("sql:open", { path });
        return r.dbId;
    },
    /** Run a non-SELECT statement (INSERT/UPDATE/DELETE/DDL). */
    async execute(db, sql, params = []) {
        return (await call("sql:execute", { dbId: db, sql, params }));
    },
    /** Run a SELECT; resolves to an array of row objects (column → value). */
    async query(db, sql, params = []) {
        const r = await call("sql:query", { dbId: db, sql, params });
        return (r.rows ?? []);
    },
    /** Close a database handle. */
    async close(db) {
        await call("sql:close", { dbId: db });
    },
};
