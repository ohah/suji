// Package nativetheme provides macOS dark mode detection (Electron `nativeTheme`).
package nativetheme

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// ShouldUseDarkColors returns raw JSON: `{"dark":bool}`.
// macOS NSApp.effectiveAppearance.name이 Dark 계열이면 true.
func ShouldUseDarkColors() string {
	return suji.Invoke("__core__", `{"cmd":"native_theme_should_use_dark_colors"}`)
}

// SetThemeSource forces the theme source: "light" | "dark" | "system".
// Response: `{"success":bool}`.
func SetThemeSource(source string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"native_theme_set_source","source":"%s"}`, jsonesc.Full(source)))
}
