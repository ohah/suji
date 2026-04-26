// Package menu provides Suji application menu customization.
// macOS: NSMenu. Clicks emit `menu:click {"click":"..."}` through the EventBus.
package menu

import (
	"encoding/json"

	suji "github.com/ohah/suji-go"
)

// MenuItem is an application menu entry. Top-level entries should set Submenu.
type MenuItem struct {
	Type    string     `json:"type,omitempty"` // "item", "checkbox", "separator", "submenu"
	Label   string     `json:"label,omitempty"`
	Click   string     `json:"click,omitempty"`
	Enabled *bool      `json:"enabled,omitempty"`
	Checked bool       `json:"checked,omitempty"`
	Submenu []MenuItem `json:"submenu,omitempty"`
}

func Item(label, click string) MenuItem {
	return MenuItem{Type: "item", Label: label, Click: click}
}

func Checkbox(label, click string, checked bool) MenuItem {
	return MenuItem{Type: "checkbox", Label: label, Click: click, Checked: checked}
}

func Separator() MenuItem {
	return MenuItem{Type: "separator"}
}

func Submenu(label string, items []MenuItem) MenuItem {
	return MenuItem{Type: "submenu", Label: label, Submenu: items}
}

// SetApplicationMenu replaces Suji's default custom area while preserving the macOS App menu.
func SetApplicationMenu(items []MenuItem) string {
	return suji.Invoke("__core__", buildSetApplicationMenuRequest(items))
}

func buildSetApplicationMenuRequest(items []MenuItem) string {
	req := map[string]interface{}{
		"cmd":   "menu_set_application_menu",
		"items": items,
	}
	b, _ := json.Marshal(req)
	return string(b)
}

func ResetApplicationMenu() string {
	return suji.Invoke("__core__", `{"cmd":"menu_reset_application_menu"}`)
}
