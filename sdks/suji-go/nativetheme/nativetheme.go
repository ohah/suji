// Package nativetheme provides macOS dark mode detection (Electron `nativeTheme`).
package nativetheme

import suji "github.com/ohah/suji-go"

// ShouldUseDarkColors returns raw JSON: `{"dark":bool}`.
// macOS NSApp.effectiveAppearance.name이 Dark 계열이면 true.
func ShouldUseDarkColors() string {
	return suji.Invoke("__core__", `{"cmd":"native_theme_should_use_dark_colors"}`)
}
