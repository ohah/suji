// Package notification provides Suji system notification API (Electron `Notification`).
// macOS: UNUserNotificationCenter. Linux: freedesktop Notifications D-Bus.
// Windows: Shell_NotifyIcon balloon.
//
// 클릭은 EventBus의 `notification:click {notificationId}` 이벤트로 수신.
package notification

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// IsSupported — 플랫폼 지원 여부. `{"from","cmd","supported":bool}` 응답.
func IsSupported() string {
	return suji.Invoke("__core__", `{"cmd":"notification_is_supported"}`)
}

// RequestPermission — 첫 호출 시 OS 권한 다이얼로그. `{"from","cmd","granted":bool}` 응답.
func RequestPermission() string {
	return suji.Invoke("__core__", `{"cmd":"notification_request_permission"}`)
}

// Show — 알림 표시. `{"from","cmd","notificationId":"...","success":bool}` 응답.
// success=false면 권한/번들 문제. notificationId로 Close 가능.
func Show(title, body string, silent bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"notification_show","title":"%s","body":"%s","silent":%t}`,
		jsonesc.Full(title), jsonesc.Full(body), silent,
	))
}

func Close(notificationID string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"notification_close","notificationId":"%s"}`,
		jsonesc.Full(notificationID),
	))
}

// RemoveAll removes all delivered/pending notifications.
// Response: `{"success":bool}` (macOS 실동작). (Electron Notification.removeAll)
func RemoveAll() string {
	return suji.Invoke("__core__", `{"cmd":"notification_remove_all"}`)
}

// ShowGrouped shows a notification with a caller id + group id (macOS threadIdentifier),
// making it a RemoveGroup target. Empty id → auto-generated. Response: `{"notificationId","success"}`.
func ShowGrouped(id, title, body string, silent bool, groupID string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"notification_show","id":"%s","title":"%s","body":"%s","silent":%t,"groupId":"%s"}`,
		jsonesc.Full(id), jsonesc.Full(title), jsonesc.Full(body), silent, jsonesc.Full(groupID),
	))
}

// RemoveGroup removes delivered notifications whose group (macOS threadIdentifier) matches
// (Electron Notification.removeGroup). macOS only; Win/Linux false. Response: `{"success":bool}`.
func RemoveGroup(groupID string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"notification_remove_group","groupId":"%s"}`, jsonesc.Full(groupID)))
}
