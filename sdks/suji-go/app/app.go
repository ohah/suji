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

// GetFileIcon returns the file's system icon as PNG base64 (Electron
// `app.getFileIcon`, macOS NSWorkspace.iconForFile). Response: `{"data":"<base64>"}`.
// 파일 없거나 Win/Linux는 빈 문자열.
func GetFileIcon(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_get_file_icon","path":"%s"}`, jsonesc.Full(path)))
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

// Relaunch registers app restart after quit (Electron `app.relaunch()`). 이후
// Quit/Exit 시 현재 argv 로 새 인스턴스 spawn. Response: `{"success":bool}`.
// args/execPath 옵션 미지원(현재 argv 그대로 — 정직 경계).
func Relaunch() string {
	return suji.Invoke("__core__", `{"cmd":"app_relaunch"}`)
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

// Show re-displays the app after hide (Electron app.show — unhide + activate). raw JSON: `{"success":bool}`. macOS only.
func Show() string {
	return suji.Invoke("__core__", `{"cmd":"app_show"}`)
}

// IsActive reports whether the app is frontmost (Electron app.isActive). raw JSON: `{"active":bool}`. macOS only.
func IsActive() string {
	return suji.Invoke("__core__", `{"cmd":"app_is_active"}`)
}

// IsHidden reports whether the app is hidden (Electron app.isHidden). raw JSON: `{"hidden":bool}`. macOS only.
func IsHidden() string {
	return suji.Invoke("__core__", `{"cmd":"app_is_hidden"}`)
}

// IsEmojiPanelSupported reports emoji panel support (Electron app.isEmojiPanelSupported). raw JSON: `{"supported":bool}`. macOS true.
func IsEmojiPanelSupported() string {
	return suji.Invoke("__core__", `{"cmd":"app_is_emoji_panel_supported"}`)
}

// FlashFrame draws attention via dock/window (Electron BrowserWindow.flashFrame). macOS dock
// bounce — flash=false stops it. raw JSON: `{"success":bool}`.
func FlashFrame(flash bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_flash_frame","flash":%t}`, flash))
}

// ShowAboutPanel shows the system About panel (Electron app.showAboutPanel). macOS only. raw JSON: `{"success":bool}`.
func ShowAboutPanel() string {
	return suji.Invoke("__core__", `{"cmd":"app_show_about_panel"}`)
}

// SetAboutPanelOptions sets About panel options (Electron app.setAboutPanelOptions).
// 빈 문자열 필드는 네이티브에서 skip. macOS only. raw JSON: `{"success":bool}`.
func SetAboutPanelOptions(applicationName, applicationVersion, version, copyright string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"app_set_about_panel_options","applicationName":"%s","applicationVersion":"%s","version":"%s","copyright":"%s"}`,
		jsonesc.Full(applicationName), jsonesc.Full(applicationVersion), jsonesc.Full(version), jsonesc.Full(copyright)))
}

// AddRecentDocument adds a path to the recent documents list (Electron app.addRecentDocument). macOS only.
// raw JSON: `{"success":bool}`.
func AddRecentDocument(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_add_recent_document","path":"%s"}`, jsonesc.Full(path)))
}

// ClearRecentDocuments clears the recent documents list (Electron app.clearRecentDocuments). macOS only.
// raw JSON: `{"success":bool}`.
func ClearRecentDocuments() string {
	return suji.Invoke("__core__", `{"cmd":"app_clear_recent_documents"}`)
}

// IsInApplicationsFolder reports whether the .app is under /Applications (Electron
// app.isInApplicationsFolder). raw JSON: `{"inApplications":bool}`. macOS only.
func IsInApplicationsFolder() string {
	return suji.Invoke("__core__", `{"cmd":"app_is_in_applications_folder"}`)
}

// GetLoginItemSettings queries login-item auto-launch (Electron app.getLoginItemSettings).
// macOS plist / Linux desktop. raw JSON: `{"openAtLogin":bool,"openAsHidden":false,...}`.
func GetLoginItemSettings() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_login_item_settings"}`)
}

// SetLoginItemSettings sets login-item auto-launch (Electron app.setLoginItemSettings).
// macOS plist / Linux desktop / Windows registry Run 키. raw JSON: `{"success":bool}`.
func SetLoginItemSettings(openAtLogin bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_set_login_item_settings","openAtLogin":%t}`, openAtLogin))
}

// SetPath — Electron app.setPath. getPath 경로 런타임 오버라이드. raw JSON: `{"success":bool}`.
func SetPath(name, path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_set_path","name":"%s","path":"%s"}`, jsonesc.Full(name), jsonesc.Full(path)))
}

// GetLocaleCountryCode — Electron app.getLocaleCountryCode. ISO 3166. macOS only. raw JSON: `{"countryCode":"..."}`.
func GetLocaleCountryCode() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_locale_country_code"}`)
}

// GetRecentDocuments — Electron app.getRecentDocuments. macOS only. raw JSON: `{"documents":["..."]}`.
func GetRecentDocuments() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_recent_documents"}`)
}

// GetApplicationNameForProtocol — Electron app.getApplicationNameForProtocol. macOS only. raw JSON: `{"name":"..."}`.
func GetApplicationNameForProtocol(url string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_get_application_name_for_protocol","url":"%s"}`, jsonesc.Full(url)))
}

// GetApplicationInfoForProtocol — Electron app.getApplicationInfoForProtocol. macOS only. raw JSON: `{"name","path","icon"}`.
func GetApplicationInfoForProtocol(url string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"app_get_application_info_for_protocol","url":"%s"}`, jsonesc.Full(url)))
}

// CertificateErrorRespond — app:certificate-error 응답 (allow=true 허용). raw JSON: `{"success":bool}`.
func CertificateErrorRespond(id uint64, allow bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"certificate_error_respond","id":%d,"allow":%t}`, id, allow))
}

// LoginRespond — app:login(basic auth) 응답 (ok=true 면 username/password). raw JSON: `{"success":bool}`.
func LoginRespond(id uint64, ok bool, username, password string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"login_respond","id":%d,"ok":%t,"username":"%s","password":"%s"}`, id, ok, jsonesc.Full(username), jsonesc.Full(password)))
}

// SelectClientCertificateRespond — app:select-client-certificate 응답 (index, -1=기본). raw JSON: `{"success":bool}`.
func SelectClientCertificateRespond(id uint64, index int64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"select_client_certificate_respond","id":%d,"index":%d}`, id, index))
}

// SetAuthHandlerEnabled — auth 이벤트 핸들러 활성(이벤트 구독 후). 미활성 시 CEF 기본 fallback.
// raw JSON: `{"success":bool}`.
func SetAuthHandlerEnabled(enabled bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"auth_set_handler_enabled","enabled":%t}`, enabled))
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
