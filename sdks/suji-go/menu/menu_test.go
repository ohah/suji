package menu

import (
	"encoding/json"
	"testing"
)

func TestBuildSetApplicationMenuRequest(t *testing.T) {
	hidden := false
	runItem := Item("Run", "run")
	runItem.ID = "run-item"
	runItem.Visible = &hidden // visible:false 직렬화
	runItem.Accelerator = "Cmd+R"
	req := buildSetApplicationMenuRequest([]MenuItem{
		Submenu("Tools", []MenuItem{
			runItem,
			Checkbox("Flag", "flag", true), // Visible nil → omitempty 로 키 생략(기본 true)
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
	item0 := sub[0].(map[string]any)
	if item0["click"] != "run" {
		t.Fatalf("first submenu item = %#v", sub[0])
	}
	if item0["id"] != "run-item" {
		t.Fatalf("id = %v", item0["id"])
	}
	if item0["visible"] != false {
		t.Fatalf("visible = %v", item0["visible"])
	}
	if item0["accelerator"] != "Cmd+R" {
		t.Fatalf("accelerator = %v", item0["accelerator"])
	}
	cb := sub[1].(map[string]any)
	if cb["checked"] != true {
		t.Fatalf("checkbox item = %#v", sub[1])
	}
	if _, present := cb["visible"]; present {
		t.Fatalf("nil Visible should be omitted, got %#v", cb["visible"])
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
