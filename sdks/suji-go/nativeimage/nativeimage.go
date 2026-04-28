// Package nativeimage provides image file → dimensions API (Electron `nativeImage`).
package nativeimage

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// GetSize returns image file dimensions. raw JSON: `{"width":N,"height":N}`.
// File not found / decode failure → 0/0. macOS NSImage.size (point unit).
func GetSize(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"native_image_get_size","path":"%s"}`, jsonesc.Full(path)))
}

// ToPNG returns image file → PNG base64. raw JSON: `{"data":"..."}` (raw ~8KB 한도).
func ToPNG(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"native_image_to_png","path":"%s"}`, jsonesc.Full(path)))
}

// ToJPEG returns image file → JPEG base64. quality는 0~100.
func ToJPEG(path string, quality float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"native_image_to_jpeg","path":"%s","quality":%g}`, jsonesc.Full(path), quality))
}
