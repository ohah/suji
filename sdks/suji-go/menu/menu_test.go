package menu

import (
	"encoding/json"
	"testing"
)

func TestBuildSetApplicationMenuRequest(t *testing.T) {
	req := buildSetApplicationMenuRequest([]MenuItem{
		Submenu("Tools", []MenuItem{
			Item("Run", "run"),
			Checkbox("Flag", "flag", true),
			Separator(),
		}),
	})

	var got map[string]any
	if err := json.Unmarshal([]byte(req), &got); err != nil {
		t.Fatalf("request is not valid JSON: %v", err)
	}
	if got["cmd"] != "menu_set_application_menu" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	items := got["items"].([]any)
	top := items[0].(map[string]any)
	if top["type"] != "submenu" || top["label"] != "Tools" {
		t.Fatalf("top item = %#v", top)
	}
	sub := top["submenu"].([]any)
	if sub[0].(map[string]any)["click"] != "run" {
		t.Fatalf("first submenu item = %#v", sub[0])
	}
	if sub[1].(map[string]any)["checked"] != true {
		t.Fatalf("checkbox item = %#v", sub[1])
	}
	if sub[2].(map[string]any)["type"] != "separator" {
		t.Fatalf("separator item = %#v", sub[2])
	}
}

func TestBuildSetApplicationMenuRequestEscapesStrings(t *testing.T) {
	req := buildSetApplicationMenuRequest([]MenuItem{
		Submenu(`도구 "Tools"`, []MenuItem{Item(`Run \ now`, "run\nnow")}),
	})

	var got map[string]any
	if err := json.Unmarshal([]byte(req), &got); err != nil {
		t.Fatalf("request is not valid JSON: %v", err)
	}
	top := got["items"].([]any)[0].(map[string]any)
	if top["label"] != `도구 "Tools"` {
		t.Fatalf("label = %q", top["label"])
	}
	sub := top["submenu"].([]any)[0].(map[string]any)
	if sub["label"] != `Run \ now` || sub["click"] != "run\nnow" {
		t.Fatalf("submenu item = %#v", sub)
	}
}
