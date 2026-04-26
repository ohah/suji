// Package tray provides Suji system tray (menu bar) icon API (Electron `Tray`).
// macOS: NSStatusItem. Linux/Windows stub (Create는 trayId:0 응답).
//
// 메뉴 항목 클릭은 EventBus의 `tray:menu-click {trayId, click}` 이벤트로 수신.
package tray

import (
	"encoding/json"
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// MenuItem — Separator는 빈 항목, Label/Click 둘 다 비어있지 않으면 일반 항목.
type MenuItem struct {
	Separator bool
	Label     string
	Click     string
}

// Create new tray icon. Response: `{"from","cmd","trayId":N}`. trayId=0 means failure.
func Create(title, tooltip string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"tray_create","title":"%s","tooltip":"%s"}`,
		jsonesc.Full(title), jsonesc.Full(tooltip),
	))
}

func SetTitle(trayID uint32, title string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"tray_set_title","trayId":%d,"title":"%s"}`,
		trayID, jsonesc.Full(title),
	))
}

func SetTooltip(trayID uint32, tooltip string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"tray_set_tooltip","trayId":%d,"tooltip":"%s"}`,
		trayID, jsonesc.Full(tooltip),
	))
}

// SetMenu — items 배열로 메뉴 구성. Separator true면 분리선, 아니면 Label+Click 일반 항목.
func SetMenu(trayID uint32, items []MenuItem) string {
	arr := make([]map[string]interface{}, len(items))
	for i, it := range items {
		if it.Separator {
			arr[i] = map[string]interface{}{"type": "separator"}
		} else {
			arr[i] = map[string]interface{}{"label": it.Label, "click": it.Click}
		}
	}
	req := map[string]interface{}{
		"cmd":    "tray_set_menu",
		"trayId": trayID,
		"items":  arr,
	}
	b, _ := json.Marshal(req)
	return suji.Invoke("__core__", string(b))
}

func Destroy(trayID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"tray_destroy","trayId":%d}`, trayID))
}
