// Package app provides Suji app-level API (Electron `app.getPath` 등).
// macOS 표준 디렉토리 + userData/appData/temp 등.
package app

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// GetPath returns standard directory path for `name`.
// name = "home" | "appData" | "userData" | "temp" | "desktop" | "documents" | "downloads".
// Response: `{"path":"..."}` (unknown name은 빈 문자열).
func GetPath(name string) string {
	return suji.Invoke("__core__", buildGetPathRequest(name))
}

func buildGetPathRequest(name string) string {
	return fmt.Sprintf(`{"cmd":"app_get_path","name":"%s"}`, jsonesc.Full(name))
}

// GetName returns suji.json app.name. raw JSON: `{"name":"..."}`.
func GetName() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_name"}`)
}

// GetVersion returns suji.json app.version. raw JSON: `{"version":"..."}`.
func GetVersion() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_version"}`)
}

// IsReady returns app init readiness. raw JSON: `{"ready":bool}` (always true).
func IsReady() string {
	return suji.Invoke("__core__", `{"cmd":"app_is_ready"}`)
}

// GetLocale returns system locale in BCP 47 (e.g., "en-US"). raw JSON: `{"locale":"..."}`.
func GetLocale() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_locale"}`)
}

// IsPackaged returns true if running from .app bundle (Electron `app.isPackaged`).
// Response: `{"packaged":bool}`.
func IsPackaged() string {
	return suji.Invoke("__core__", `{"cmd":"app_is_packaged"}`)
}

// GetAppPath returns main bundle path (Electron `app.getAppPath`).
// Response: `{"path":"..."}`.
func GetAppPath() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_app_path"}`)
}

// SetProgressBar sets dock icon progress. progress<0=hide, 0~1=ratio.
// Response: `{"success":bool}`.
func SetProgressBar(progress float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_set_progress_bar","progress":%g}`, progress))
}

// SetBadgeCount sets the app badge count. 0 이하이면 제거.
// Response: `{"success":bool}`.
func SetBadgeCount(count int64) string {
	return suji.Invoke("__core__", buildSetBadgeCountRequest(count))
}

func buildSetBadgeCountRequest(count int64) string {
	return fmt.Sprintf(`{"cmd":"app_set_badge_count","count":%d}`, count)
}

// GetBadgeCount returns the current app badge count. Response: `{"count":N}`.
func GetBadgeCount() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_badge_count"}`)
}

// Exit force-quits the app (Electron `app.exit(code)`). exit code는 무시.
// Response: `{"success":bool}` (process는 응답 직후 종료).
func Exit() string {
	return suji.Invoke("__core__", `{"cmd":"app_exit"}`)
}

// RequestSingleInstanceLock makes this process the primary instance.
// Electron `app.requestSingleInstanceLock()`. primary 면 `{"locked":true}`,
// 다른 인스턴스가 이미 보유 중이면 `{"locked":false}` (보통 앱 quit). 이미 보유
// 중이면 멱등적으로 true. macOS/Linux=userData flock, Windows=named mutex.
func RequestSingleInstanceLock() string {
	return suji.Invoke("__core__", `{"cmd":"app_request_single_instance_lock"}`)
}

// HasSingleInstanceLock reports whether this process holds the lock.
// Electron `app.hasSingleInstanceLock()`. Response: `{"locked":bool}`.
func HasSingleInstanceLock() string {
	return suji.Invoke("__core__", `{"cmd":"app_has_single_instance_lock"}`)
}

// ReleaseSingleInstanceLock releases the held lock (no-op if not held).
// Electron `app.releaseSingleInstanceLock()`. Response: `{"success":bool}`.
func ReleaseSingleInstanceLock() string {
	return suji.Invoke("__core__", `{"cmd":"app_release_single_instance_lock"}`)
}

// SetAsDefaultProtocolClient sets this app as the default handler for protocol://
// (Electron `app.setAsDefaultProtocolClient`, macOS Launch Services). scheme 등록은
// suji.json `app.deepLinkSchemes`(CFBundleURLTypes)가 담당. Response: `{"success":bool}`.
// ⚠️ 실 .app 번들에서만 동작(dev=번들 ID 부재 → false).
func SetAsDefaultProtocolClient(protocol string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_set_as_default_protocol_client","protocol":"%s"}`, jsonesc.Full(protocol)))
}

// IsDefaultProtocolClient reports whether this app is the current default handler.
// Electron `app.isDefaultProtocolClient`. Response: `{"success":bool}`.
func IsDefaultProtocolClient(protocol string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_is_default_protocol_client","protocol":"%s"}`, jsonesc.Full(protocol)))
}

// RemoveAsDefaultProtocolClient — macOS LS 해제 API 부재 → false (Electron macOS 동형).
// Electron `app.removeAsDefaultProtocolClient`. Response: `{"success":bool}`.
func RemoveAsDefaultProtocolClient(protocol string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_remove_as_default_protocol_client","protocol":"%s"}`, jsonesc.Full(protocol)))
}

// Focus brings the app frontmost. raw JSON: `{"success":bool}`.
func Focus() string {
	return suji.Invoke("__core__", `{"cmd":"app_focus"}`)
}

// Hide hides all app windows (macOS Cmd+H). raw JSON: `{"success":bool}`.
func Hide() string {
	return suji.Invoke("__core__", `{"cmd":"app_hide"}`)
}

// CreateSecurityScopedBookmark creates a security-scoped bookmark for App
// Sandbox persistent file access. Response:
// `{"success":bool,"bookmark":"<base64>"}` (비-sandbox 빌드에선 일반 bookmark).
func CreateSecurityScopedBookmark(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"security_scoped_bookmark_create","path":"%s"}`, jsonesc.Full(path)))
}

// StartAccessingSecurityScopedResource resolves a bookmark and begins access.
// Response: `{"success":bool,"id":N,"path":"...","stale":bool}`.
func StartAccessingSecurityScopedResource(bookmark string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"security_scoped_access_start","bookmark":"%s"}`, jsonesc.Full(bookmark)))
}

// StopAccessingSecurityScopedResource ends access for id. Invalid id → success:false.
// Response: `{"success":bool}`.
func StopAccessingSecurityScopedResource(id uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"security_scoped_access_stop","id":%d}`, id))
}
