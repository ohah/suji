// Package dock provides Suji dock API (macOS NSDockTile).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package dock

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// SetBadge sets the dock icon badge text. 빈 문자열 = 제거.
// Response: `{"success":bool}`.
func SetBadge(text string) string {
	return suji.Invoke("__core__", buildSetBadgeRequest(text))
}

// GetBadge returns the current badge text. Response: `{"text":"..."}`.
func GetBadge() string {
	return suji.Invoke("__core__", `{"cmd":"dock_get_badge"}`)
}

func buildSetBadgeRequest(text string) string {
	return fmt.Sprintf(`{"cmd":"dock_set_badge","text":"%s"}`, jsonesc.Full(text))
}
