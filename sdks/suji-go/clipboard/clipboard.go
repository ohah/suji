// Package clipboard provides Suji clipboard API (Electron `clipboard.*`).
// Routes through suji.Invoke("__core__", ...) — same cmd JSON as frontend `@suji/api`.
//
// 응답은 raw JSON string — caller가 encoding/json으로 파싱.
package clipboard

import (
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// ReadText reads system clipboard as plain text.
// Response: `{"from","cmd","text":"..."}`.
func ReadText() string {
	return suji.Invoke("__core__", `{"cmd":"clipboard_read_text"}`)
}

// WriteText writes plain text to system clipboard.
// Response: `{"from","cmd","success":bool}`.
func WriteText(text string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_text","text":"%s"}`, jsonesc.Full(text)))
}

func Clear() string {
	return suji.Invoke("__core__", `{"cmd":"clipboard_clear"}`)
}
