// Package desktopcapturer provides Suji desktopCapturer API
// (Electron `desktopCapturer.getSources`). 화면/창 소스 열거 — 썸네일
// 미포함(정직 경계). Routes through suji.Invoke("__core__", ...).
package desktopcapturer

import (
	"fmt"

	suji "github.com/ohah/suji-go"
)

// GetSources returns screen/window sources. types: "screen" | "window" |
// "screen,window". raw JSON: `{"sources":[{id,name,type,x,y,width,height,displayId?}]}`.
func GetSources(types string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"desktop_capturer_get_sources","types":"%s"}`, types))
}
