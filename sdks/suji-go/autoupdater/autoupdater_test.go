package autoupdater

import (
	"encoding/json"
	"testing"
)

func TestBuildCheckUpdateRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildCheckUpdateRequest(CheckUpdateArgs{
		CurrentVersion: "1.0.0",
		LatestVersion:  "1.1.0",
		URL:            "https://example.test/app.zip",
		Sha256:         "abc",
		Notes:          "notes",
		PubDate:        "2026-05-25T00:00:00Z",
	})), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "auto_updater_check_update" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["currentVersion"] != "1.0.0" || got["latestVersion"] != "1.1.0" {
		t.Fatalf("versions = %v/%v", got["currentVersion"], got["latestVersion"])
	}
	if got["url"] != "https://example.test/app.zip" || got["pubDate"] != "2026-05-25T00:00:00Z" {
		t.Fatalf("url/pubDate = %v/%v", got["url"], got["pubDate"])
	}
}

func TestBuildVerifyFileRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildVerifyFileRequest(VerifyFileArgs{Path: "/tmp/app.zip", Sha256: "abc"})), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "auto_updater_verify_file" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["path"] != "/tmp/app.zip" || got["sha256"] != "abc" {
		t.Fatalf("path/sha256 = %v/%v", got["path"], got["sha256"])
	}
}

func TestBuildDownloadArtifactRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildDownloadArtifactRequest(DownloadArtifactArgs{URL: "https://x/app.zip", Path: "/tmp/app.zip"})), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "auto_updater_download_artifact" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["url"] != "https://x/app.zip" || got["path"] != "/tmp/app.zip" {
		t.Fatalf("url/path = %v/%v", got["url"], got["path"])
	}
}

func TestBuildPrepareInstallRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildPrepareInstallRequest(PrepareInstallArgs{Path: "/tmp/app.zip", Format: "auto"})), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "auto_updater_prepare_install" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["format"] != "auto" {
		t.Fatalf("format = %v", got["format"])
	}
}

func TestBuildQuitAndInstallRequest(t *testing.T) {
	var got map[string]any
	if err := json.Unmarshal([]byte(buildQuitAndInstallRequest(QuitAndInstallArgs{Path: "/tmp/app.zip", Target: "/Applications/X.app", Relaunch: true})), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got["cmd"] != "auto_updater_quit_and_install" {
		t.Fatalf("cmd = %v", got["cmd"])
	}
	if got["target"] != "/Applications/X.app" {
		t.Fatalf("target = %v", got["target"])
	}
	if got["relaunch"] != true {
		t.Fatalf("relaunch = %v", got["relaunch"])
	}
}
