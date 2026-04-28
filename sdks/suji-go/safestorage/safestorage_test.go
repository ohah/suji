package safestorage

import (
	"encoding/json"
	"testing"
)

func TestBuildSetRequestEscapesValues(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildSetRequest("svc", "acc", `a"b\c`)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "safe_storage_set" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["service"] != "svc" || got["account"] != "acc" {
		t.Fatalf("service/account = %v/%v", got["service"], got["account"])
	}
	if got["value"] != `a"b\c` {
		t.Fatalf("value = %v", got["value"])
	}
}

func TestBuildGetAndDeleteRequests(t *testing.T) {
	var get map[string]any
	if err := json.Unmarshal([]byte(buildGetRequest("svc", "acc")), &get); err != nil {
		t.Fatalf("invalid get JSON: %v", err)
	}
	if get["cmd"] != "safe_storage_get" {
		t.Fatalf("get cmd = %v", get["cmd"])
	}

	var del map[string]any
	if err := json.Unmarshal([]byte(buildDeleteRequest("svc", "acc")), &del); err != nil {
		t.Fatalf("invalid delete JSON: %v", err)
	}
	if del["cmd"] != "safe_storage_delete" {
		t.Fatalf("delete cmd = %v", del["cmd"])
	}
}
