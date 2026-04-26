package globalshortcut

import (
	"encoding/json"
	"testing"
)

func TestBuildGlobalShortcutRequests(t *testing.T) {
	cases := []struct {
		name string
		req  string
		cmd  string
	}{
		{"register", buildRegisterRequest("Cmd+Shift+K", "openSettings"), "global_shortcut_register"},
		{"unregister", buildUnregisterRequest("Cmd+Shift+K"), "global_shortcut_unregister"},
		{"is_registered", buildIsRegisteredRequest("Cmd+Shift+K"), "global_shortcut_is_registered"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got map[string]any
			if err := json.Unmarshal([]byte(tc.req), &got); err != nil {
				t.Fatalf("request is not valid JSON: %v", err)
			}
			if got["cmd"] != tc.cmd {
				t.Fatalf("cmd = %v", got["cmd"])
			}
		})
	}
}

func TestBuildRegisterEscapesStrings(t *testing.T) {
	req := buildRegisterRequest(`Cmd+"Q"`, "click\nname")
	var got map[string]any
	if err := json.Unmarshal([]byte(req), &got); err != nil {
		t.Fatalf("request is not valid JSON: %v", err)
	}
	if got["accelerator"] != `Cmd+"Q"` {
		t.Fatalf("accelerator = %q", got["accelerator"])
	}
	if got["click"] != "click\nname" {
		t.Fatalf("click = %q", got["click"])
	}
}
