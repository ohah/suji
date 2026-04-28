// Package shell provides Suji shell API (Electron `shell.*`).
// macOS: NSWorkspace + NSBeep. Linux/Windows stub. Routes through suji.Invoke.
package shell

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// OpenExternal opens URL in system default handler (browser/mailto/etc.).
// Response: `{"from","cmd","success":bool}`.
func OpenExternal(url string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"shell_open_external","url":"%s"}`, jsonesc.Full(url)))
}

// ShowItemInFolder reveals path in Finder/Explorer.
func ShowItemInFolder(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"shell_show_item_in_folder","path":"%s"}`, jsonesc.Full(path)))
}

// Beep plays system beep (NSBeep on macOS).
func Beep() string {
	return suji.Invoke("__core__", `{"cmd":"shell_beep"}`)
}

// TrashItem moves the file/folder at path to the system trash.
// Response: `{"success":bool}`.
func TrashItem(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"shell_trash_item","path":"%s"}`, jsonesc.Full(path)))
}

// OpenPath opens a local file/folder with the default application.
// Response: `{"success":bool}`.
func OpenPath(path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"shell_open_path","path":"%s"}`, jsonesc.Full(path)))
}
