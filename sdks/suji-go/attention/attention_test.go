package attention

import (
	"encoding/json"
	"testing"
)

func TestBuildRequestJSON(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildRequestJSON(true)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "app_attention_request" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["critical"] != true {
		t.Fatalf("critical = %v", got["critical"])
	}

	var info map[string]any
	if err := json.Unmarshal([]byte(buildRequestJSON(false)), &info); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if info["critical"] != false {
		t.Fatalf("informational critical = %v", info["critical"])
	}
}

func TestBuildCancelJSON(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildCancelJSON(42)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "app_attention_cancel" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["id"].(float64) != 42 {
		t.Fatalf("id = %v", got["id"])
	}
}
