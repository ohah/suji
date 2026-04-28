// Package screen provides Suji screen API (Electron `screen.getAllDisplays`).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
package screen

import suji "github.com/ohah/suji-go"

// GetAllDisplays returns raw JSON: `{"from","cmd","displays":[{...}]}`.
// macOS NSScreen 기반.
func GetAllDisplays() string {
	return suji.Invoke("__core__", `{"cmd":"screen_get_all_displays"}`)
}
