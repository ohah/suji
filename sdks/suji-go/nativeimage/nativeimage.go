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
