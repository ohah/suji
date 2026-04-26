// Package notification provides Suji system notification API (Electron `Notification`).
// macOS: UNUserNotificationCenter. Linux/Windows stub.
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
