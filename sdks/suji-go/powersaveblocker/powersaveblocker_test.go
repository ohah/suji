package powersaveblocker

import (
	"encoding/json"
	"testing"
)

func TestBuildStartRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildStartRequest("prevent_display_sleep")), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "power_save_blocker_start" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["type"] != "prevent_display_sleep" {
		t.Fatalf("type = %v", got["type"])
	}
}

func TestBuildStopRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildStopRequest(7)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "power_save_blocker_stop" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["id"].(float64) != 7 {
		t.Fatalf("id = %v", got["id"])
	}
}
