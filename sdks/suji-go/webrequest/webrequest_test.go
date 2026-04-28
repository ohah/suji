package webrequest

import (
	"encoding/json"
	"testing"
)

func TestBuildSetBlockedUrlsRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildSetBlockedUrlsRequest([]string{"https://*.example.com/*", "https://blocked/*"})), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "web_request_set_blocked_urls" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	patterns := got["patterns"].([]any)
	if len(patterns) != 2 {
		t.Fatalf("patterns len = %d", len(patterns))
	}
	if patterns[0] != "https://*.example.com/*" {
		t.Fatalf("pattern[0] = %v", patterns[0])
	}
}

func TestBuildSetBlockedUrlsRequestEmpty(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildSetBlockedUrlsRequest(nil)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	patterns := got["patterns"].([]any)
	if len(patterns) != 0 {
		t.Fatalf("expected empty patterns, got %v", patterns)
	}
}
