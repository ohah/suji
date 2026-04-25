// Package state provides the State plugin wrapper for Suji Go backends.
// All calls go through suji.Invoke("state", ...).
//
//	import state "github.com/ohah/suji-plugin-state"
//
//	state.Set("user", `"yoon"`)
//	val := state.Get("user")
//	state.Delete("user")
//	keys := state.Keys()
package state

import (
	"encoding/json"
	"fmt"

	suji "github.com/ohah/suji-go"
)

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

type stateResult struct {
	Result struct {
		Value json.RawMessage `json:"value"`
		Keys  []string        `json:"keys"`
	} `json:"result"`
}

// Get returns the raw JSON value for a key (global scope), or empty string if not found.
func Get(key string) string { return GetIn(key, "") }

// GetIn returns value within an explicit scope ("window:2", "session:onboard"). Empty scope = global.
func GetIn(key, scope string) string {
	req := buildReq("state:get", map[string]any{"key": key}, scope)
	resp := suji.Invoke("state", req)
	var r stateResult
	if err := json.Unmarshal([]byte(resp), &r); err != nil {
		return ""
	}
	if string(r.Result.Value) == "null" || len(r.Result.Value) == 0 {
		return ""
	}
	return string(r.Result.Value)
}

// Set stores a key with a raw JSON value (global scope).
func Set(key, value string) { SetIn(key, value, "") }

func SetIn(key, value, scope string) {
	var val any
	if err := json.Unmarshal([]byte(value), &val); err != nil {
		val = value
	}
	req := buildReq("state:set", map[string]any{"key": key, "value": val}, scope)
	suji.Invoke("state", req)
}

// Delete removes a key (global scope).
func Delete(key string) { DeleteIn(key, "") }

func DeleteIn(key, scope string) {
	req := buildReq("state:delete", map[string]any{"key": key}, scope)
	suji.Invoke("state", req)
}

// Keys returns all stored keys (or only one scope's user-keys when scope given via KeysIn).
func Keys() []string { return KeysIn("") }

func KeysIn(scope string) []string {
	req := buildReq("state:keys", map[string]any{}, scope)
	resp := suji.Invoke("state", req)
	var r stateResult
	if err := json.Unmarshal([]byte(resp), &r); err != nil {
		return nil
	}
	return r.Result.Keys
}

// Clear removes all state (every scope).
func Clear() {
	req := `{"cmd":"state:clear"}`
	suji.Invoke("state", req)
}

// ClearScope removes only one scope.
func ClearScope(scope string) {
	req := buildReq("state:clear", map[string]any{}, scope)
	suji.Invoke("state", req)
}

// Watch registers an EventBus listener for state:{key} changes (global scope channel).
func Watch(key string, callback func(channel, data string)) uint64 {
	return WatchIn(key, "", callback)
}

func WatchIn(key, scope string, callback func(channel, data string)) uint64 {
	if scope == "" || scope == "global" {
		return suji.On(fmt.Sprintf("state:%s", key), callback)
	}
	return suji.On(fmt.Sprintf("state:%s:%s", scope, key), callback)
}

// buildReq — common: cmd + extras + optional scope. scope=="" → 생략.
func buildReq(cmd string, extras map[string]any, scope string) string {
	m := map[string]any{"cmd": cmd}
	for k, v := range extras {
		m[k] = v
	}
	if scope != "" {
		m["scope"] = scope
	}
	return mustJSON(m)
}
