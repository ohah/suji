// Package sqlite provides the SQLite plugin wrapper for Suji Go backends.
// All calls route through suji.Invoke("sqlite", ...). Parameterized via
// positional `?` (SQL injection-safe — never string-format user input).
//
//	import sql "github.com/ohah/suji-plugin-sqlite"
//
//	db, _ := sql.Open(":memory:")
//	sql.Execute(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)", nil)
//	sql.Execute(db, "INSERT INTO t(name) VALUES (?)", []any{"yoon"})
//	rows, _ := sql.Query(db, "SELECT * FROM t WHERE name = ?", []any{"yoon"})
//	sql.Close(db)
package sqlite

import (
	"encoding/json"
	"errors"

	suji "github.com/ohah/suji-go"
)

type envelope struct {
	Error  string          `json:"error"`
	Result json.RawMessage `json:"result"`
}

// call invokes the plugin and returns the unwrapped `result` payload or an error.
func call(req map[string]any) (json.RawMessage, error) {
	b, _ := json.Marshal(req)
	var env envelope
	if err := json.Unmarshal([]byte(suji.Invoke("sqlite", string(b))), &env); err != nil {
		return nil, err
	}
	if env.Error != "" {
		return nil, errors.New(env.Error)
	}
	return env.Result, nil
}

// Open opens (or creates) a database: ":memory:", an absolute path, or a
// relative path (resolved under app-data suji-app/sqlite/). Returns a dbId.
func Open(path string) (int64, error) {
	res, err := call(map[string]any{"cmd": "sql:open", "path": path})
	if err != nil {
		return 0, err
	}
	var r struct {
		DBID int64 `json:"dbId"`
	}
	if err := json.Unmarshal(res, &r); err != nil {
		return 0, err
	}
	return r.DBID, nil
}

// ExecResult is the outcome of a write/DDL statement.
type ExecResult struct {
	Changes         int64 `json:"changes"`
	LastInsertRowid int64 `json:"lastInsertRowid"`
}

// Execute runs a non-SELECT statement. params bind to positional `?`.
func Execute(db int64, sqlText string, params []any) (ExecResult, error) {
	var out ExecResult
	res, err := call(map[string]any{"cmd": "sql:execute", "dbId": db, "sql": sqlText, "params": params})
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(res, &out)
	return out, err
}

// Query runs a SELECT and returns rows as column→value maps.
func Query(db int64, sqlText string, params []any) ([]map[string]any, error) {
	res, err := call(map[string]any{"cmd": "sql:query", "dbId": db, "sql": sqlText, "params": params})
	if err != nil {
		return nil, err
	}
	var r struct {
		Rows []map[string]any `json:"rows"`
	}
	if err := json.Unmarshal(res, &r); err != nil {
		return nil, err
	}
	return r.Rows, nil
}

// Close closes a database handle.
func Close(db int64) error {
	_, err := call(map[string]any{"cmd": "sql:close", "dbId": db})
	return err
}
