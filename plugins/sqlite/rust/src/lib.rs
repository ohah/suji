//! # suji-plugin-sqlite
//!
//! SQLite plugin wrapper for Suji Rust backends. All calls route through
//! `suji::invoke("sqlite", ...)`. Parameterized via positional `?` (SQL
//! injection-safe — never string-interpolate user input into SQL).
//!
//! ```no_run
//! use suji_plugin_sqlite as sql;
//! use serde_json::json;
//!
//! let db = sql::open(":memory:").unwrap();
//! sql::execute(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)", &[]).unwrap();
//! sql::execute(db, "INSERT INTO t(name) VALUES (?)", &[json!("yoon")]).unwrap();
//! let rows = sql::query(db, "SELECT * FROM t WHERE name = ?", &[json!("yoon")]).unwrap();
//! sql::close(db);
//! ```

use serde_json::Value;

fn call(req: &Value) -> Option<Value> {
    let resp = suji::invoke("sqlite", &req.to_string())?;
    let parsed: Value = serde_json::from_str(&resp).ok()?;
    if parsed.get("error").is_some() {
        return None;
    }
    parsed.get("result").cloned()
}

/// Open (or create) a database. `":memory:"`, an absolute path, or a relative
/// path (resolved under the app-data `suji-app/sqlite/` dir). Returns a dbId.
pub fn open(path: &str) -> Option<i64> {
    let r = call(&serde_json::json!({"cmd": "sql:open", "path": path}))?;
    r.get("dbId")?.as_i64()
}

/// Result of a write/DDL statement.
#[derive(Debug, Clone, Copy)]
pub struct ExecResult {
    pub changes: i64,
    pub last_insert_rowid: i64,
}

/// Run a non-SELECT statement (INSERT/UPDATE/DELETE/DDL). `params` bind to
/// positional `?` placeholders.
pub fn execute(db: i64, sql: &str, params: &[Value]) -> Option<ExecResult> {
    let r = call(&serde_json::json!({
        "cmd": "sql:execute", "dbId": db, "sql": sql, "params": params
    }))?;
    Some(ExecResult {
        changes: r.get("changes")?.as_i64()?,
        last_insert_rowid: r.get("lastInsertRowid")?.as_i64()?,
    })
}

/// Run a SELECT and return the rows as objects (column → value).
pub fn query(db: i64, sql: &str, params: &[Value]) -> Option<Vec<Value>> {
    let r = call(&serde_json::json!({
        "cmd": "sql:query", "dbId": db, "sql": sql, "params": params
    }))?;
    Some(r.get("rows")?.as_array()?.clone())
}

/// Close a database handle. Returns false if the dbId was already invalid.
pub fn close(db: i64) -> bool {
    call(&serde_json::json!({"cmd": "sql:close", "dbId": db})).is_some()
}
