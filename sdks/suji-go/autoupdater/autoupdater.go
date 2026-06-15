// Package autoupdater provides Suji autoUpdater API
// (Electron `autoUpdater` shape — manifest check + download + SHA-256 verify +
// prepare/quit-and-install). Calls the same five `auto_updater_*` core commands
// as the JS/Node SDK, but as a backend SDK it takes explicit params (no manifest
// fetch / app.getVersion() client step — that is the caller's responsibility).
//
// Args are passed as option structs (not positional strings) so same-typed
// fields (currentVersion vs latestVersion, path vs target, notes vs pubDate)
// cannot be silently transposed. Struct field names map 1:1 to core JSON keys.
package autoupdater

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// CheckUpdateArgs compares a manifest latest version/URL against the current version.
type CheckUpdateArgs struct {
	CurrentVersion string
	LatestVersion  string
	URL            string
	Sha256         string
	Notes          string
	PubDate        string
}

// VerifyFileArgs validates a downloaded file's SHA-256.
type VerifyFileArgs struct {
	Path   string
	Sha256 string
}

// DownloadArtifactArgs downloads an artifact URL to a path (+ optional SHA-256).
type DownloadArtifactArgs struct {
	URL    string
	Path   string
	Sha256 string
}

// PrepareInstallArgs normalizes an artifact format (zip/dmg/app/AppImage/deb or "auto").
type PrepareInstallArgs struct {
	Path     string
	Target   string
	StageDir string
	Format   string
	Sha256   string
}

// QuitAndInstallArgs swaps the staged artifact into target after quit.
type QuitAndInstallArgs struct {
	Path       string
	Target     string
	Sha256     string
	Relaunch   bool
	HelperPath string
}

// CheckForUpdates returns raw JSON (updateAvailable/version/url/...).
func CheckForUpdates(a CheckUpdateArgs) string {
	return suji.Invoke("__core__", buildCheckUpdateRequest(a))
}

// VerifyFile returns raw JSON (success / actualSha256 on mismatch).
func VerifyFile(a VerifyFileArgs) string {
	return suji.Invoke("__core__", buildVerifyFileRequest(a))
}

// DownloadArtifact downloads and optionally verifies, returning raw JSON.
func DownloadArtifact(a DownloadArtifactArgs) string {
	return suji.Invoke("__core__", buildDownloadArtifactRequest(a))
}

// PrepareInstall normalizes an artifact into a quitAndInstall / handoff input.
func PrepareInstall(a PrepareInstallArgs) string {
	return suji.Invoke("__core__", buildPrepareInstallRequest(a))
}

// QuitAndInstall swaps the staged artifact into target after quit and requests quit.
func QuitAndInstall(a QuitAndInstallArgs) string {
	return suji.Invoke("__core__", buildQuitAndInstallRequest(a))
}

func buildCheckUpdateRequest(a CheckUpdateArgs) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_check_update","currentVersion":"%s","latestVersion":"%s","url":"%s","sha256":"%s","notes":"%s","pubDate":"%s"}`,
		jsonesc.Full(a.CurrentVersion), jsonesc.Full(a.LatestVersion), jsonesc.Full(a.URL),
		jsonesc.Full(a.Sha256), jsonesc.Full(a.Notes), jsonesc.Full(a.PubDate))
}

func buildVerifyFileRequest(a VerifyFileArgs) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_verify_file","path":"%s","sha256":"%s"}`,
		jsonesc.Full(a.Path), jsonesc.Full(a.Sha256))
}

func buildDownloadArtifactRequest(a DownloadArtifactArgs) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_download_artifact","url":"%s","path":"%s","sha256":"%s"}`,
		jsonesc.Full(a.URL), jsonesc.Full(a.Path), jsonesc.Full(a.Sha256))
}

func buildPrepareInstallRequest(a PrepareInstallArgs) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_prepare_install","path":"%s","target":"%s","stageDir":"%s","format":"%s","sha256":"%s"}`,
		jsonesc.Full(a.Path), jsonesc.Full(a.Target), jsonesc.Full(a.StageDir),
		jsonesc.Full(a.Format), jsonesc.Full(a.Sha256))
}

func buildQuitAndInstallRequest(a QuitAndInstallArgs) string {
	return fmt.Sprintf(
		`{"cmd":"auto_updater_quit_and_install","path":"%s","target":"%s","sha256":"%s","relaunch":%t,"helperPath":"%s"}`,
		jsonesc.Full(a.Path), jsonesc.Full(a.Target), jsonesc.Full(a.Sha256), a.Relaunch, jsonesc.Full(a.HelperPath))
}
