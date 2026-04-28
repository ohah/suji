// Package powersaveblocker provides Suji powerSaveBlocker API.
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package powersaveblocker

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// Start sleep blocker. Type: "prevent_app_suspension" | "prevent_display_sleep".
// Response: `{"id":N}` (0이면 실패).
func Start(typeStr string) string {
	return suji.Invoke("__core__", buildStartRequest(typeStr))
}

// Stop releases an assertion id. Response: `{"success":bool}`.
func Stop(id uint32) string {
	return suji.Invoke("__core__", buildStopRequest(id))
}

func buildStartRequest(typeStr string) string {
	return fmt.Sprintf(`{"cmd":"power_save_blocker_start","type":"%s"}`, jsonesc.Full(typeStr))
}

func buildStopRequest(id uint32) string {
	return fmt.Sprintf(`{"cmd":"power_save_blocker_stop","id":%d}`, id)
}
