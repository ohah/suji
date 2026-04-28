// Package app provides Suji app-level API (Electron `app.getPath` 등).
// macOS 표준 디렉토리 + userData/appData/temp 등.
package app

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// GetPath returns standard directory path for `name`.
// name = "home" | "appData" | "userData" | "temp" | "desktop" | "documents" | "downloads".
// Response: `{"path":"..."}` (unknown name은 빈 문자열).
func GetPath(name string) string {
	return suji.Invoke("__core__", buildGetPathRequest(name))
}

func buildGetPathRequest(name string) string {
	return fmt.Sprintf(`{"cmd":"app_get_path","name":"%s"}`, jsonesc.Full(name))
}

// GetName returns suji.json app.name. raw JSON: `{"name":"..."}`.
func GetName() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_name"}`)
}

// GetVersion returns suji.json app.version. raw JSON: `{"version":"..."}`.
func GetVersion() string {
	return suji.Invoke("__core__", `{"cmd":"app_get_version"}`)
}
