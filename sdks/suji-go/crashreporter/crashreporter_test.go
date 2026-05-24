package crashreporter

import (
	"encoding/json"
	"testing"
)

func TestBuildStartRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildStartRequest(false)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "crash_reporter_start" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["uploadToServer"] != false {
		t.Fatalf("uploadToServer = %v", got["uploadToServer"])
	}
}

func TestBuildExtraParameterRequests(t *testing.T) {
	var add map[string]any
	if err := json.Unmarshal([]byte(buildAddExtraParameterRequest("suite", "go")), &add); err != nil {
		t.Fatalf("invalid add JSON: %v", err)
	}
	if add["cmd"] != "crash_reporter_add_extra_parameter" {
		t.Fatalf("cmd = %v", add["cmd"])
	}
	if add["key"] != "suite" || add["value"] != "go" {
		t.Fatalf("extra = %v/%v", add["key"], add["value"])
	}

	var remove map[string]any
	if err := json.Unmarshal([]byte(buildRemoveExtraParameterRequest("suite")), &remove); err != nil {
		t.Fatalf("invalid remove JSON: %v", err)
	}
	if remove["cmd"] != "crash_reporter_remove_extra_parameter" {
		t.Fatalf("cmd = %v", remove["cmd"])
	}
	if remove["key"] != "suite" {
		t.Fatalf("key = %v", remove["key"])
	}
}
