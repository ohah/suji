package desktopcapturer

import (
	"encoding/json"
	"testing"
)

func TestBuildGetSourcesRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildGetSourcesRequest("screen,window")), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "desktop_capturer_get_sources" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["types"] != "screen,window" {
		t.Fatalf("types = %v", got["types"])
	}
}

func TestBuildCaptureThumbnailRequestEscapesFields(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildCaptureThumbnailRequest("screen:1:0", `/tmp/a"b\c.png`)), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "desktop_capturer_capture_thumbnail" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["sourceId"] != "screen:1:0" {
		t.Fatalf("sourceId = %v", got["sourceId"])
	}
	if got["path"] != `/tmp/a"b\c.png` {
		t.Fatalf("path = %v", got["path"])
	}
}
