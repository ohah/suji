// Package powermonitor provides system idle time API (Electron `powerMonitor`).
package powermonitor

import (
	"fmt"

	suji "github.com/ohah/suji-go"
)

// GetSystemIdleTime returns raw JSON: `{"seconds":f64}`.
// 활성 입력 (마우스/키보드) 후 0으로 리셋.
func GetSystemIdleTime() string {
	return suji.Invoke("__core__", `{"cmd":"power_monitor_get_idle_time"}`)
}

// GetSystemIdleState returns "locked" when the screen is locked, "idle" if
// idle seconds >= threshold, otherwise "active".
// Response: `{"state":"active"|"idle"|"locked"}`.
func GetSystemIdleState(threshold int64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"power_monitor_get_idle_state","threshold":%d}`, threshold))
}

// IsOnBatteryPower reports whether the system is on battery power.
// Response: `{"onBattery":bool}` (정보 없으면 false). (Electron powerMonitor.isOnBatteryPower)
func IsOnBatteryPower() string {
	return suji.Invoke("__core__", `{"cmd":"power_monitor_is_on_battery"}`)
}
