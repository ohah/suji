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

// ReadHTML reads HTML from clipboard. Response: `{"html":"..."}`.
func ReadHTML() string {
	return suji.Invoke("__core__", `{"cmd":"clipboard_read_html"}`)
}

// WriteHTML writes HTML to clipboard. Other types are cleared.
// Response: `{"success":bool}`.
func WriteHTML(html string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_html","html":"%s"}`, jsonesc.Full(html)))
}

// Has checks if clipboard contains the given format (UTI).
// Response: `{"present":bool}`.
func Has(format string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_has","format":"%s"}`, jsonesc.Full(format)))
}

// AvailableFormats returns the list of registered formats (UTI strings).
// Response: `{"formats":[...]}`.
func AvailableFormats() string {
	return suji.Invoke("__core__", `{"cmd":"clipboard_available_formats"}`)
}

// WriteImage writes a PNG image (base64-encoded). Limits: raw PNG ~8KB (1차).
// Response: `{"success":bool}`.
func WriteImage(pngBase64 string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_image","data":"%s"}`, jsonesc.Full(pngBase64)))
}

// ReadImage reads PNG bytes from clipboard as base64. Empty string if missing.
// Response: `{"data":"..."}`.
func ReadImage() string {
	return suji.Invoke("__core__", `{"cmd":"clipboard_read_image"}`)
}

// WriteTIFF writes a TIFF image (base64-encoded) — NSPasteboard `public.tiff`.
// WriteImage 동형. Response: `{"success":bool}`.
func WriteTIFF(tiffBase64 string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_tiff","data":"%s"}`, jsonesc.Full(tiffBase64)))
}

// ReadTIFF reads TIFF bytes from clipboard as base64. Empty string if missing.
// Response: `{"data":"..."}`.
func ReadTIFF() string {
	return suji.Invoke("__core__", `{"cmd":"clipboard_read_tiff"}`)
}

// ReadRTF reads RTF text from clipboard (Electron `clipboard.readRTF`).
// Response: `{"rtf":"..."}`.
func ReadRTF() string {
	return suji.Invoke("__core__", `{"cmd":"clipboard_read_rtf"}`)
}

// WriteRTF writes RTF text to clipboard (Electron `clipboard.writeRTF`).
// Response: `{"success":bool}`.
func WriteRTF(rtf string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_rtf","rtf":"%s"}`, jsonesc.Full(rtf)))
}

// WriteBuffer writes raw bytes (base64-encoded) to clipboard for arbitrary UTI.
// Response: `{"success":bool}`.
func WriteBuffer(format, dataBase64 string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_buffer","format":"%s","data":"%s"}`, jsonesc.Full(format), jsonesc.Full(dataBase64)))
}

// ReadBuffer reads raw bytes from clipboard as base64. Empty string if missing.
// Response: `{"data":"..."}`.
func ReadBuffer(format string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_read_buffer","format":"%s"}`, jsonesc.Full(format)))
}

// WriteBookmark writes a title+url bookmark (Electron clipboard.writeBookmark).
// macOS NSPasteboard public.url(+url-name). macOS only; Win/Linux false. Response: `{"success":bool}`.
func WriteBookmark(title, url string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_bookmark","title":"%s","url":"%s"}`, jsonesc.Full(title), jsonesc.Full(url)))
}

// WriteFindText writes text to the macOS Find pasteboard (Electron clipboard.writeFindText).
// macOS only; Win/Linux false. Response: `{"success":bool}`.
func WriteFindText(text string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write_find_text","text":"%s"}`, jsonesc.Full(text)))
}

// Write writes multiple formats at once (Electron clipboard.write). Empty fields are skipped.
// macOS=atomic, Win/Linux=best-effort single (text first). Response: `{"success":bool}`.
func Write(text, html, rtf string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"clipboard_write","text":"%s","html":"%s","rtf":"%s"}`, jsonesc.Full(text), jsonesc.Full(html), jsonesc.Full(rtf)))
}
