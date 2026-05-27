package tray

import (
	"encoding/json"
	"testing"
)

func TestBuildSetMenuRequestNestedItems(t *testing.T) {
	enabled := false
	req := buildSetMenuRequest(7, []MenuItem{
		{Label: "Run", Click: "run"},
		{Checkbox: true, Label: "Flag", Click: "flag", Checked: true, Enabled: &enabled},
		{Type: "submenu", Label: "More", Submenu: []MenuItem{{Label: "Child", Click: "child"}}},
		{Separator: true},
	})

	var got map[string]any
	if err := json.Unmarshal([]byte(req), &got); err != nil {
		t.Fatalf("request is not valid JSON: %v", err)
	}
	if got["cmd"] != "tray_set_menu" || got["trayId"].(float64) != 7 {
		t.Fatalf("request header = %#v", got)
	}
	items := got["items"].([]any)
	if items[0].(map[string]any)["click"] != "run" {
		t.Fatalf("item = %#v", items[0])
	}
	if items[1].(map[string]any)["type"] != "checkbox" || items[1].(map[string]any)["enabled"] != false {
		t.Fatalf("checkbox = %#v", items[1])
	}
	if items[2].(map[string]any)["type"] != "submenu" {
		t.Fatalf("submenu = %#v", items[2])
	}
	if items[2].(map[string]any)["submenu"].([]any)[0].(map[string]any)["click"] != "child" {
		t.Fatalf("submenu child = %#v", items[2])
	}
	if items[3].(map[string]any)["type"] != "separator" {
		t.Fatalf("separator = %#v", items[3])
	}
}
