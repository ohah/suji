// Package screen provides Suji screen API (Electron `screen.getAllDisplays`).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package screen

import (
	"fmt"

	suji "github.com/ohah/suji-go"
)

// GetAllDisplays returns raw JSON: `{"from","cmd","displays":[{...}]}`.
// macOS NSScreen 기반.
func GetAllDisplays() string {
	return suji.Invoke("__core__", `{"cmd":"screen_get_all_displays"}`)
}

// GetCursorScreenPoint returns mouse cursor location. raw JSON: `{"x":..,"y":..}`.
func GetCursorScreenPoint() string {
	return suji.Invoke("__core__", `{"cmd":"screen_get_cursor_point"}`)
}

// GetDisplayNearestPoint returns the display index containing (x,y), -1 if none.
// raw JSON: `{"index":N}`.
func GetDisplayNearestPoint(x, y float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"screen_get_display_nearest_point","x":%g,"y":%g}`, x, y))
}

// GetDisplayMatching returns the display index whose bounds overlap rect most (-1 if none).
// 겹침 없으면 rect 중심 최근접. raw JSON: `{"index":N}`. (Electron screen.getDisplayMatching, 듀얼모니터)
func GetDisplayMatching(x, y, width, height float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"screen_get_display_matching","x":%g,"y":%g,"width":%g,"height":%g}`,
		x, y, width, height,
	))
}
