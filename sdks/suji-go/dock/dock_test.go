package dock

import (
	"encoding/json"
	"testing"
)

func TestBuildSetBadgeRequestEscapesQuote(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildSetBadgeRequest(`a"b`)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "dock_set_badge" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["text"] != `a"b` {
		t.Fatalf("text = %v", got["text"])
	}
}
