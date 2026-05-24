// Package crashreporter provides Suji crashReporter API
// (Electron `crashReporter` shape, backed by CEF Crashpad/Breakpad).
package crashreporter

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// Start registers runtime crash reporter state. First-process Crashpad enablement
// requires suji.json app.crashReporter so CEF can read crash_reporter.cfg before init.
func Start(uploadToServer bool) string {
	return suji.Invoke("__core__", buildStartRequest(uploadToServer))
}

func GetParameters() string {
	return suji.Invoke("__core__", `{"cmd":"crash_reporter_get_parameters"}`)
}

func AddExtraParameter(key, value string) string {
	return suji.Invoke("__core__", buildAddExtraParameterRequest(key, value))
}

func RemoveExtraParameter(key string) string {
	return suji.Invoke("__core__", buildRemoveExtraParameterRequest(key))
}

func GetUploadToServer() string {
	return suji.Invoke("__core__", `{"cmd":"crash_reporter_get_upload_to_server"}`)
}

func SetUploadToServer(uploadToServer bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"crash_reporter_set_upload_to_server","uploadToServer":%t}`, uploadToServer))
}

func GetUploadedReports() string {
	return suji.Invoke("__core__", `{"cmd":"crash_reporter_get_uploaded_reports"}`)
}

func GetLastCrashReport() string {
	return suji.Invoke("__core__", `{"cmd":"crash_reporter_get_last_crash_report"}`)
}

func buildStartRequest(uploadToServer bool) string {
	return fmt.Sprintf(`{"cmd":"crash_reporter_start","uploadToServer":%t}`, uploadToServer)
}

func buildAddExtraParameterRequest(key, value string) string {
	return fmt.Sprintf(
		`{"cmd":"crash_reporter_add_extra_parameter","key":"%s","value":"%s"}`,
		jsonesc.Full(key), jsonesc.Full(value))
}

func buildRemoveExtraParameterRequest(key string) string {
	return fmt.Sprintf(
		`{"cmd":"crash_reporter_remove_extra_parameter","key":"%s"}`,
		jsonesc.Full(key))
}
