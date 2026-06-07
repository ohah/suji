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
	// ID — Electron MenuItem.id (getMenuItemById 식별자; UI 효과 없음).
	ID string `json:"id,omitempty"`
	// Visible — Electron MenuItem.visible. nil=기본 true; false 면 항목 숨김. 포인터로
	// 기본-true 보존(omitempty 가 nil 드롭 → 미지정 시 네이티브 기본 true).
	Visible *bool `json:"visible,omitempty"`
	// Accelerator — Electron MenuItem.accelerator (예 "Cmd+Shift+K"). macOS keyEquivalent
	// (단일 문자), Win/Linux no-op.
	Accelerator string `json:"accelerator,omitempty"`
	// Role — Electron MenuItem.role (copy/paste/quit 등; 설정 시 click 무시). macOS only.
	Role string `json:"role,omitempty"`
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

// GetApplicationMenu returns the last-set menu snapshot (Electron Menu.getApplicationMenu).
// Response raw JSON: `{"items":[...]}` (empty [] if none). Not a live object
// (suji menus are fire-and-forget).
func GetApplicationMenu() string {
	return suji.Invoke("__core__", `{"cmd":"menu_get_application_menu"}`)
}

// SendActionToFirstResponder sends a standard selector (e.g. "copy:") to the macOS
// first responder (Electron Menu.sendActionToFirstResponder). macOS only; Win/Linux no-op.
func SendActionToFirstResponder(action string) string {
	req, _ := json.Marshal(map[string]any{
		"cmd":    "menu_send_action_to_first_responder",
		"action": action,
	})
	return suji.Invoke("__core__", string(req))
}

// GetMenuItemByID searches the getApplicationMenu snapshot for an item with the given
// id (recursing into submenus) and returns it, or nil if not found (Electron
// Menu.getMenuItemById). Not a live object.
func GetMenuItemByID(id string) *MenuItem {
	var resp struct {
		Items []MenuItem `json:"items"`
	}
	if err := json.Unmarshal([]byte(GetApplicationMenu()), &resp); err != nil {
		return nil
	}
	return findMenuItemByID(resp.Items, id)
}

func findMenuItemByID(items []MenuItem, id string) *MenuItem {
	for i := range items {
		if items[i].ID == id {
			return &items[i]
		}
		if hit := findMenuItemByID(items[i].Submenu, id); hit != nil {
			return hit
		}
	}
	return nil
}
