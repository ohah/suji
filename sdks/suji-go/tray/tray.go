// Package tray provides Suji system tray (menu bar) icon API (Electron `Tray`).
// macOS: NSStatusItem. Linux: GTK StatusIcon. Windows: Shell_NotifyIconW.
//
// 메뉴 항목 클릭은 EventBus의 `tray:menu-click {trayId, click}` 이벤트로 수신.
package tray

import (
	"encoding/json"
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// MenuItem is a tray menu entry. Separator/Checkbox keep the old struct-style API
// while Type accepts the wire values "item", "checkbox", "separator", "submenu".
type MenuItem struct {
	Separator bool
	Checkbox  bool
	Type      string
	Label     string
	Click     string
	Enabled   *bool
	Checked   bool
	Submenu   []MenuItem
}

// Create new tray icon. Response: `{"from","cmd","trayId":N}`. trayId=0 means failure.
func Create(title, tooltip string) string {
	return CreateWithIcon(title, tooltip, "")
}

// CreateWithIcon uses iconPath as the native tray icon on macOS/Linux. Windows uses the default icon for now.
func CreateWithIcon(title, tooltip, iconPath string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"tray_create","title":"%s","tooltip":"%s","iconPath":"%s"}`,
		jsonesc.Full(title), jsonesc.Full(tooltip), jsonesc.Full(iconPath),
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

// SetMenu — items 배열로 메뉴 구성. macOS/Linux는 checkbox/submenu/enabled를 지원한다.
func SetMenu(trayID uint32, items []MenuItem) string {
	return suji.Invoke("__core__", buildSetMenuRequest(trayID, items))
}

func buildSetMenuRequest(trayID uint32, items []MenuItem) string {
	req := map[string]interface{}{
		"cmd":    "tray_set_menu",
		"trayId": trayID,
		"items":  menuItemsToJSON(items),
	}
	b, _ := json.Marshal(req)
	return string(b)
}

func menuItemsToJSON(items []MenuItem) []map[string]interface{} {
	arr := make([]map[string]interface{}, len(items))
	for i, it := range items {
		arr[i] = menuItemToJSON(it)
	}
	return arr
}

func menuItemToJSON(it MenuItem) map[string]interface{} {
	typ := it.Type
	if typ == "" {
		if it.Separator {
			typ = "separator"
		} else if it.Checkbox {
			typ = "checkbox"
		} else if it.Submenu != nil {
			typ = "submenu"
		}
	}

	if typ == "separator" {
		return map[string]interface{}{"type": "separator"}
	}

	out := map[string]interface{}{
		"label": it.Label,
	}
	if it.Enabled != nil {
		out["enabled"] = *it.Enabled
	}
	if typ == "submenu" {
		out["type"] = "submenu"
		out["submenu"] = menuItemsToJSON(it.Submenu)
		return out
	}
	out["click"] = it.Click
	if typ == "checkbox" {
		out["type"] = "checkbox"
		out["checked"] = it.Checked
	}
	return out
}

func Destroy(trayID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"tray_destroy","trayId":%d}`, trayID))
}
