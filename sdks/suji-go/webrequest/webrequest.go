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
	return suji.Invoke("__core__", buildPatternsRequest("web_request_set_blocked_urls", patterns))
}

// SetListenerFilter registers dynamic listener filter. 매칭 요청은 RV_CONTINUE_ASYNC +
// webRequest:will-request 이벤트. consumer가 Resolve(id, cancel) 호출 전까지 hold.
func SetListenerFilter(patterns []string) string {
	return suji.Invoke("__core__", buildPatternsRequest("web_request_set_listener_filter", patterns))
}

// Resolve confirms or cancels a pending request by id (from will-request event).
func Resolve(id uint64, cancel bool) string {
	body, _ := json.Marshal(map[string]any{
		"cmd":    "web_request_resolve",
		"id":     id,
		"cancel": cancel,
	})
	return suji.Invoke("__core__", string(body))
}

// SetRequestHeaders injects headers into requests matching the URL globs (Electron
// session.webRequest.onBeforeSendHeaders, declarative variant). Empty patterns clears.
// Response: `{"count":N}`. ⚠️ per-request JS callback is unsupported (CEF ignores request
// edits after async resolve) — declarative rule only.
func SetRequestHeaders(patterns []string, requestHeaders map[string]string) string {
	if patterns == nil {
		patterns = []string{}
	}
	if requestHeaders == nil { // nil map → "requestHeaders":null → 코어가 "{}" fallback(조용한 no-op) 방지
		requestHeaders = map[string]string{}
	}
	body, _ := json.Marshal(map[string]any{
		"cmd":            "web_request_set_request_headers",
		"patterns":       patterns,
		"requestHeaders": requestHeaders,
	})
	return suji.Invoke("__core__", string(body))
}

func buildPatternsRequest(cmd string, patterns []string) string {
	if patterns == nil {
		patterns = []string{}
	}
	body, err := json.Marshal(map[string]any{
		"cmd":      cmd,
		"patterns": patterns,
	})
	if err != nil {
		return `{"cmd":"` + cmd + `","patterns":[]}`
	}
	return string(body)
}
