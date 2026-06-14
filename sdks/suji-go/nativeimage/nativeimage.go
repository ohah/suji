// Package nativeimage provides image file → dimensions API (Electron `nativeImage`).
package nativeimage

import (
	"encoding/json"
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

// ToDataURL returns the image as a data URL (Electron nativeImage.toDataURL).
// ToPNG 의 PNG base64 에 `data:image/png;base64,` 접두. 빈/실패 이미지는 빈 문자열.
// (다른 메서드의 raw JSON 과 달리 data URL 문자열 자체 반환 — toDataURL 의미상 자연스러움.)
func ToDataURL(path string) string {
	var v struct {
		Data string `json:"data"`
	}
	if err := json.Unmarshal([]byte(ToPNG(path)), &v); err != nil || v.Data == "" {
		return ""
	}
	return "data:image/png;base64," + v.Data
}

// ToJPEG returns image file → JPEG base64. quality는 0~100.
func ToJPEG(path string, quality float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"native_image_to_jpeg","path":"%s","quality":%g}`, jsonesc.Full(path), quality))
}

// IsEmpty returns whether the image is empty (load fail / size 0). raw JSON: `{"isEmpty":bool}`.
func IsEmpty(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"native_image_is_empty","path":"%s"}`, jsonesc.Full(path)))
}

// IsTemplateImage returns whether the image is a template image (macOS NSImage.isTemplate).
// raw JSON: `{"isTemplate":bool}`. macOS only; Win/Linux false.
func IsTemplateImage(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"native_image_is_template","path":"%s"}`, jsonesc.Full(path)))
}
