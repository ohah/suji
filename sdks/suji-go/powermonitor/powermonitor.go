// Package powermonitor provides system idle time API (Electron `powerMonitor`).
package powermonitor

import suji "github.com/ohah/suji-go"

// GetSystemIdleTime returns raw JSON: `{"seconds":f64}`.
// 활성 입력 (마우스/키보드) 후 0으로 리셋. macOS CGEventSource.
func GetSystemIdleTime() string {
	return suji.Invoke("__core__", `{"cmd":"power_monitor_get_idle_time"}`)
}
