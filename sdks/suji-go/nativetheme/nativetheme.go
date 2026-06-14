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

// GetThemeSource returns the last-set themeSource (default "system").
// Response: `{"source":"system"|"light"|"dark"}`. (Electron nativeTheme.themeSource getter)
func GetThemeSource() string {
	return suji.Invoke("__core__", `{"cmd":"native_theme_get_source"}`)
}

// ShouldUseHighContrastColors returns raw JSON: `{"highContrast":bool}`.
// macOS NSWorkspace.accessibilityDisplayShouldIncreaseContrast / Windows SPI_GETHIGHCONTRAST. Linux false.
func ShouldUseHighContrastColors() string {
	return suji.Invoke("__core__", `{"cmd":"native_theme_high_contrast"}`)
}

// PrefersReducedTransparency returns raw JSON: `{"reducedTransparency":bool}`.
// macOS NSWorkspace.accessibilityDisplayShouldReduceTransparency. Win/Linux false.
func PrefersReducedTransparency() string {
	return suji.Invoke("__core__", `{"cmd":"native_theme_reduced_transparency"}`)
}

// ShouldUseInvertedColorScheme returns raw JSON: `{"invertedColorScheme":bool}`.
// macOS NSWorkspace.accessibilityDisplayShouldInvertColors. Win/Linux false.
func ShouldUseInvertedColorScheme() string {
	return suji.Invoke("__core__", `{"cmd":"native_theme_inverted_color_scheme"}`)
}

// ShouldDifferentiateWithoutColor returns raw JSON: `{"differentiateWithoutColor":bool}`.
// macOS NSWorkspace.accessibilityDisplayShouldDifferentiateWithoutColor. Win/Linux false.
func ShouldDifferentiateWithoutColor() string {
	return suji.Invoke("__core__", `{"cmd":"native_theme_differentiate_without_color"}`)
}
