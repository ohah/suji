// Package dialog provides Suji native dialog API (Electron `dialog.*`).
// macOS: NSAlert/NSOpenPanel/NSSavePanel. Linux/Windows stub.
//
// 응답은 raw JSON string — caller가 encoding/json으로 파싱.
package dialog

import (
	"encoding/json"
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
)

// MessageBoxOpts — Electron 호환 필드. 비어 있는 필드는 응답에 안 들어감.
// WindowID > 0이면 sheet (해당 창에 attach), 0이면 free-floating.
type MessageBoxOpts struct {
	WindowID         uint32   // 0 = free-floating
	Type             string   // "info" | "warning" | "error" | "question" | "none"
	Title            string
	Message          string
	Detail           string
	Buttons          []string
	DefaultID        *int     // nil = 첫 버튼이 default
	CancelID         *int
	CheckboxLabel    string
	CheckboxChecked  bool
}

// ShowMessageBox displays modal message box.
// Response: `{"from","cmd","response":N,"checkboxChecked":bool}`.
func ShowMessageBox(opts MessageBoxOpts) string {
	m := map[string]interface{}{
		"cmd":     "dialog_show_message_box",
		"message": opts.Message,
	}
	if opts.WindowID > 0 {
		m["windowId"] = opts.WindowID
	}
	if opts.Type != "" {
		m["type"] = opts.Type
	}
	if opts.Title != "" {
		m["title"] = opts.Title
	}
	if opts.Detail != "" {
		m["detail"] = opts.Detail
	}
	if len(opts.Buttons) > 0 {
		m["buttons"] = opts.Buttons
	}
	if opts.DefaultID != nil {
		m["defaultId"] = *opts.DefaultID
	}
	if opts.CancelID != nil {
		m["cancelId"] = *opts.CancelID
	}
	if opts.CheckboxLabel != "" {
		m["checkboxLabel"] = opts.CheckboxLabel
	}
	if opts.CheckboxChecked {
		m["checkboxChecked"] = true
	}
	b, _ := json.Marshal(m)
	return suji.Invoke("__core__", string(b))
}

// ShowErrorBox — 단순 에러 popup (NSAlert critical + OK).
func ShowErrorBox(title, content string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"dialog_show_error_box","title":"%s","content":"%s"}`,
		jsonesc.Full(title), jsonesc.Full(content),
	))
}

// ShowOpenDialog — 파일/폴더 선택. fieldsJSON은 추가 필드 (예: `"properties":["openFile"]`).
// 빈 문자열이면 default open dialog.
// Response: `{"from","cmd","canceled":bool,"filePaths":[...]}`.
func ShowOpenDialog(fieldsJSON string) string {
	if fieldsJSON == "" {
		return suji.Invoke("__core__", `{"cmd":"dialog_show_open_dialog"}`)
	}
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"dialog_show_open_dialog",%s}`, fieldsJSON))
}

func ShowSaveDialog(fieldsJSON string) string {
	if fieldsJSON == "" {
		return suji.Invoke("__core__", `{"cmd":"dialog_show_save_dialog"}`)
	}
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"dialog_show_save_dialog",%s}`, fieldsJSON))
}

