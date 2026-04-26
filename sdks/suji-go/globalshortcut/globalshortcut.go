// Package globalshortcut provides macOS system-wide hot keys (Electron `globalShortcut.*`).
//
// Accelerator syntax: "Cmd+Shift+K", "CommandOrControl+P", "Alt+F4", etc.
// Triggers fire on EventBus channel `globalShortcut:trigger {accelerator, click}`.
// Linux/Windows are stubs.
package globalshortcut

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

func Register(accelerator, click string) string {
	return suji.Invoke("__core__", buildRegisterRequest(accelerator, click))
}

func Unregister(accelerator string) string {
	return suji.Invoke("__core__", buildUnregisterRequest(accelerator))
}

func UnregisterAll() string {
	return suji.Invoke("__core__", `{"cmd":"global_shortcut_unregister_all"}`)
}

func IsRegistered(accelerator string) string {
	return suji.Invoke("__core__", buildIsRegisteredRequest(accelerator))
}

func buildRegisterRequest(accelerator, click string) string {
	return fmt.Sprintf(`{"cmd":"global_shortcut_register","accelerator":"%s","click":"%s"}`, jsonesc.Full(accelerator), jsonesc.Full(click))
}

func buildUnregisterRequest(accelerator string) string {
	return fmt.Sprintf(`{"cmd":"global_shortcut_unregister","accelerator":"%s"}`, jsonesc.Full(accelerator))
}

func buildIsRegisteredRequest(accelerator string) string {
	return fmt.Sprintf(`{"cmd":"global_shortcut_is_registered","accelerator":"%s"}`, jsonesc.Full(accelerator))
}
