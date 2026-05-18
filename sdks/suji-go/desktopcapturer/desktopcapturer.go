// Package desktopcapturer provides Suji desktopCapturer API
// (Electron `desktopCapturer.getSources` + 썸네일 파일경로 캡처).
// Routes through suji.Invoke("__core__", ...).
package desktopcapturer

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// GetSources returns screen/window sources. types: "screen" | "window" |
// "screen,window". raw JSON: `{"sources":[{id,name,type,x,y,width,height,displayId?}]}`.
func GetSources(types string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"desktop_capturer_get_sources","types":"%s"}`, types))
}

// CaptureThumbnail captures a source ("screen:N:0"/"window:N:0") as PNG to
// path (file-path — base64 IPC 한도 우회). raw JSON: `{"success":bool}`.
// ⚠️ Screen Recording TCC 권한 필요 — 미부여 시 success:false(정직 경계).
func CaptureThumbnail(sourceID, path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"desktop_capturer_capture_thumbnail","sourceId":"%s","path":"%s"}`,
		jsonesc.Full(sourceID), jsonesc.Full(path)))
}
