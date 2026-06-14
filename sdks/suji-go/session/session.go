// Package session provides Suji session API (Electron `session.cookies.*`).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package session

import (
	"encoding/json"

	suji "github.com/ohah/suji-go"
)

// IsPersistent reports session persistence (Electron session.isPersistent).
// Suji always uses a persistent on-disk profile → always true.
func IsPersistent() bool {
	return true
}

// ClearCookies removes all cookies (fire-and-forget). Response: `{"success":bool}`.
func ClearCookies() string {
	return suji.Invoke("__core__", `{"cmd":"session_clear_cookies"}`)
}

// FlushStore writes pending cookie changes to disk. Response: `{"success":bool}`.
func FlushStore() string {
	return suji.Invoke("__core__", `{"cmd":"session_flush_store"}`)
}

// SetDownloadPath sets the download save directory (Electron `session.setDownloadPath`).
// After set, downloads save to `<path>/<filename>` without the OS save dialog.
// Empty string clears (back to OS dialog). All downloads emit `session:will-download`.
// Response: `{"success":bool}`.
func SetDownloadPath(path string) string {
	req, _ := json.Marshal(map[string]any{"cmd": "session_set_download_path", "path": path})
	return suji.Invoke("__core__", string(req))
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

// PermissionRequest is the renderer (web content) permission request passed to
// the handler registered via SetPermissionRequestHandler.
type PermissionRequest struct {
	// PermissionID matches the response to the CEF prompt.
	PermissionID uint64 `json:"permissionId"`
	// Origin of the requester (may be "" for file:// pages).
	Origin string `json:"origin"`
	// Permissions requested, e.g. ["geolocation"].
	Permissions []string `json:"permissions"`
}

// activePermissionListener holds the current `session:permission-request`
// listener id so re-registration detaches the previous one (1 handler active,
// matching JS/Node). 0 = none.
var activePermissionListener uint64

// SetPermissionRequestHandler registers a permission handler (Electron
// `session.setPermissionRequestHandler`). When the renderer requests a
// permission (geolocation/notifications/clipboard/...), handler is called and
// returns true to grant, false to deny. Pass nil to clear (CEF default after).
// Re-registering detaches the previous handler (1 handler active).
//
// Subscribes `session:permission-request` and responds via
// `session_permission_response` (same wire as JS/Node/Rust). Honest boundary:
// camera/mic (getUserMedia) is a separate CEF media-access path — not covered.
func SetPermissionRequestHandler(handler func(PermissionRequest) bool) {
	if activePermissionListener != 0 {
		suji.Off(activePermissionListener)
		activePermissionListener = 0
	}
	if handler == nil {
		suji.Invoke("__core__", `{"cmd":"session_set_permission_handler","enabled":false}`)
		return
	}
	activePermissionListener = suji.On("session:permission-request", func(_ string, data string) {
		var d PermissionRequest
		if err := json.Unmarshal([]byte(data), &d); err != nil {
			return // malformed payload: 응답할 permissionId 없음 — 무시(JS/Node SDK 동형)
		}
		granted := handler(d)
		resp, _ := json.Marshal(map[string]any{
			"cmd":          "session_permission_response",
			"permissionId": d.PermissionID,
			"granted":      granted,
		})
		suji.Invoke("__core__", string(resp))
	})
	suji.Invoke("__core__", `{"cmd":"session_set_permission_handler","enabled":true}`)
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
