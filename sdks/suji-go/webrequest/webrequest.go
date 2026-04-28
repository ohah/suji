// Package webrequest provides URL glob blocklist (Electron `session.webRequest`).
// declarative 패턴만 지원 — JS callback decision은 후속.
package webrequest

import (
	"encoding/json"

	suji "github.com/ohah/suji-go"
)

// SetBlockedUrls registers URL glob patterns. `*` wildcard only.
// Response: `{"count":N}` (등록된 개수).
func SetBlockedUrls(patterns []string) string {
	return suji.Invoke("__core__", buildSetBlockedUrlsRequest(patterns))
}

func buildSetBlockedUrlsRequest(patterns []string) string {
	if patterns == nil {
		patterns = []string{}
	}
	body, err := json.Marshal(map[string]any{
		"cmd":      "web_request_set_blocked_urls",
		"patterns": patterns,
	})
	if err != nil {
		return `{"cmd":"web_request_set_blocked_urls","patterns":[]}`
	}
	return string(body)
}
