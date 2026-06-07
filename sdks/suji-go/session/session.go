// Package session provides Suji session API (Electron `session.cookies.*`).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package session

import (
	"encoding/json"

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

// SetProxy sets the network proxy (Electron `session.setProxy`). mode "" → "direct"
// (프록시 해제). proxyRules: "host:port". Response: `{"success":bool}`.
func SetProxy(mode, proxyRules, proxyBypassRules, pacScript string) string {
	req, _ := json.Marshal(map[string]any{
		"cmd": "session_set_proxy", "mode": mode, "proxyRules": proxyRules,
		"proxyBypassRules": proxyBypassRules, "pacScript": pacScript,
	})
	return suji.Invoke("__core__", string(req))
}

// ClearStorageData removes IndexedDB/localStorage/cache (Electron
// `session.clearStorageData`). origin "" → 전역 HTTP 캐시만(웹 플랫폼상
// origin 없이 storage 일괄 삭제 불가). storageTypes "" → "all".
// Response: `{"success":bool}`.
func ClearStorageData(origin, storageTypes string) string {
	if storageTypes == "" {
		storageTypes = "all"
	}
	req, _ := json.Marshal(map[string]any{
		"cmd":          "session_clear_storage_data",
		"origin":       origin,
		"storageTypes": storageTypes,
	})
	return suji.Invoke("__core__", string(req))
}

// CookieDescriptor mirrors Electron's `Cookie` for `session.cookies.set`.
// Expires is unix epoch second (0 → session cookie).
type CookieDescriptor struct {
	URL      string  `json:"url"`
	Name     string  `json:"name"`
	Value    string  `json:"value"`
	Domain   string  `json:"domain"`
	Path     string  `json:"path"`
	Secure   bool    `json:"secure"`
	HttpOnly bool    `json:"httponly"`
	Expires  float64 `json:"expires"`
}

// SetCookie sets a cookie (Electron `session.cookies.set`).
// Response: `{"success":bool}`.
func SetCookie(c CookieDescriptor) string {
	req := struct {
		Cmd string `json:"cmd"`
		CookieDescriptor
	}{Cmd: "session_set_cookie", CookieDescriptor: c}
	b, _ := json.Marshal(req)
	return suji.Invoke("__core__", string(b))
}

// RemoveCookies deletes cookies matching url+name (Electron `session.cookies.remove`).
// Response: `{"success":bool}`.
func RemoveCookies(url, name string) string {
	req, _ := json.Marshal(map[string]any{"cmd": "session_remove_cookies", "url": url, "name": name})
	return suji.Invoke("__core__", string(req))
}

// GetCookies launches an async visitor (Electron `session.cookies.get`).
// Response: `{"success":bool,"requestId":<u64>}` — actual cookies arrive on
// `session:cookies-result` event.
func GetCookies(url string, includeHttpOnly bool) string {
	req, _ := json.Marshal(map[string]any{
		"cmd":             "session_get_cookies",
		"url":             url,
		"includeHttpOnly": includeHttpOnly,
	})
	return suji.Invoke("__core__", string(req))
}
