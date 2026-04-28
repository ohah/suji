// Package session provides Suji session API (Electron `session.cookies.*`).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package session

import (
	suji "github.com/ohah/suji-go"
)

// ClearCookies removes all cookies (fire-and-forget). Response: `{"success":bool}`.
func ClearCookies() string {
	return suji.Invoke("__core__", `{"cmd":"session_clear_cookies"}`)
}

// FlushStore writes pending cookie changes to disk. Response: `{"success":bool}`.
func FlushStore() string {
	return suji.Invoke("__core__", `{"cmd":"session_flush_store"}`)
}
