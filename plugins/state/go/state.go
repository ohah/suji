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

// Get returns the raw JSON value for a key, or empty string if not found.
func Get(key string) string {
	req := mustJSON(map[string]any{"cmd": "state:get", "key": key})
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

// Set stores a key with a raw JSON value.
// Value should be a valid JSON fragment: `"\"hello\""`, `"42"`, `"true"`, etc.
func Set(key, value string) {
	var val any
	if err := json.Unmarshal([]byte(value), &val); err != nil {
		val = value
	}
	req := mustJSON(map[string]any{"cmd": "state:set", "key": key, "value": val})
	suji.Invoke("state", req)
}

// Delete removes a key.
func Delete(key string) {
	req := mustJSON(map[string]any{"cmd": "state:delete", "key": key})
	suji.Invoke("state", req)
}

// Keys returns all stored keys.
func Keys() []string {
	req := `{"cmd":"state:keys"}`
	resp := suji.Invoke("state", req)
	var r stateResult
	if err := json.Unmarshal([]byte(resp), &r); err != nil {
		return nil
	}
	return r.Result.Keys
}

// Clear removes all state.
func Clear() {
	req := `{"cmd":"state:clear"}`
	suji.Invoke("state", req)
}

// Watch registers an EventBus listener for state:{key} changes.
// Returns a listener ID (use suji.Off(id) to unsubscribe).
func Watch(key string, callback func(channel, data string)) uint64 {
	return suji.On(fmt.Sprintf("state:%s", key), callback)
}
