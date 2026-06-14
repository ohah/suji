// Package autoupdater provides Suji autoUpdater API
// (Electron `autoUpdater` shape — manifest check + download + SHA-256 verify +
// prepare/quit-and-install). Calls the same five `auto_updater_*` core commands
// as the JS/Node SDK, but as a backend SDK it takes explicit params (no manifest
// fetch / app.getVersion() client step — that is the caller's responsibility).
package autoupdater

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// CheckForUpdates compares a manifest latest version/URL against the current
// version and returns raw JSON (updateAvailable/version/url/...).
func CheckForUpdates(currentVersion, latestVersion, url, sha256, notes, pubDate string) string {
	return suji.Invoke("__core__", buildCheckUpdateRequest(currentVersion, latestVersion, url, sha256, notes, pubDate))
}

// VerifyFile validates a downloaded file's SHA-256 (mismatch → success=false + actualSha256).
func VerifyFile(path, sha256 string) string {
	return suji.Invoke("__core__", buildVerifyFileRequest(path, sha256))
}

// DownloadArtifact downloads an artifact URL to path and optionally verifies SHA-256.
func DownloadArtifact(url, path, sha256 string) string {
	return suji.Invoke("__core__", buildDownloadArtifactRequest(url, path, sha256))
}

// PrepareInstall normalizes an artifact format (zip/dmg/app/AppImage/deb or "auto")
// into a quitAndInstall / system-package handoff input.
func PrepareInstall(path, target, stageDir, format, sha256 string) string {
	return suji.Invoke("__core__", buildPrepareInstallRequest(path, target, stageDir, format, sha256))
}

// QuitAndInstall swaps the staged artifact into target after quit and requests quit.
func QuitAndInstall(path, target, sha256 string, relaunch bool, helperPath string) string {
	return suji.Invoke("__core__", buildQuitAndInstallRequest(path, target, sha256, relaunch, helperPath))
}

func buildCheckUpdateRequest(currentVersion, latestVersion, url, sha256, notes, pubDate string) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_check_update","currentVersion":"%s","latestVersion":"%s","url":"%s","sha256":"%s","notes":"%s","pubDate":"%s"}`,
		jsonesc.Full(currentVersion), jsonesc.Full(latestVersion), jsonesc.Full(url),
		jsonesc.Full(sha256), jsonesc.Full(notes), jsonesc.Full(pubDate))
}

func buildVerifyFileRequest(path, sha256 string) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_verify_file","path":"%s","sha256":"%s"}`,
		jsonesc.Full(path), jsonesc.Full(sha256))
}

func buildDownloadArtifactRequest(url, path, sha256 string) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_download_artifact","url":"%s","path":"%s","sha256":"%s"}`,
		jsonesc.Full(url), jsonesc.Full(path), jsonesc.Full(sha256))
}

func buildPrepareInstallRequest(path, target, stageDir, format, sha256 string) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_prepare_install","path":"%s","target":"%s","stageDir":"%s","format":"%s","sha256":"%s"}`,
		jsonesc.Full(path), jsonesc.Full(target), jsonesc.Full(stageDir),
		jsonesc.Full(format), jsonesc.Full(sha256))
}

func buildQuitAndInstallRequest(path, target, sha256 string, relaunch bool, helperPath string) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_quit_and_install","path":"%s","target":"%s","sha256":"%s","relaunch":%t,"helperPath":"%s"}`,
		jsonesc.Full(path), jsonesc.Full(target), jsonesc.Full(sha256), relaunch, jsonesc.Full(helperPath))
}
