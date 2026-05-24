package app

import (
	"encoding/json"
	"testing"
)

func TestBuildGetPathRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildGetPathRequest("userData")), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "app_get_path" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["name"] != "userData" {
		t.Fatalf("name = %v", got["name"])
	}
}

func TestBuildSetBadgeCountRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildSetBadgeCountRequest(7)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "app_set_badge_count" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["count"] != float64(7) {
		t.Fatalf("count = %v", got["count"])
	}
}
