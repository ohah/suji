// Package windows provides Suji webContents API (Phase 4-A) — 창 네비게이션,
// JS 실행, 상태 조회. Frontend `@suji/api`의 windows.* 와 같은 cmd JSON 형식.
//
// dlopen 환경에선 in-process 코어 접근 불가 → 모두 suji.Invoke("__core__", ...) 경유.
package windows

import (
	"fmt"
	"strings"

	suji "github.com/ohah/suji-go"
)

// Create a new window. optsJSON은 cmd 객체에 들어갈 필드 (예:
// `"title":"X","frame":false`). caller가 JSON-safe 보장. 단순 경우는 CreateSimple() 사용.
func Create(optsJSON string) string {
	var req string
	if optsJSON == "" {
		req = `{"cmd":"create_window"}`
	} else {
		req = fmt.Sprintf(`{"cmd":"create_window",%s}`, optsJSON)
	}
	return suji.Invoke("__core__", req)
}

// CreateSimple — 타이틀/URL만으로 익명 창 생성.
func CreateSimple(title, url string) string {
	opts := fmt.Sprintf(`"title":"%s","url":"%s"`, escapeJSON(title), escapeJSON(url))
	return Create(opts)
}

func LoadURL(windowID uint32, url string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"load_url","windowId":%d,"url":"%s"}`,
		windowID, escapeJSON(url),
	))
}

func Reload(windowID uint32, ignoreCache bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"reload","windowId":%d,"ignoreCache":%t}`,
		windowID, ignoreCache,
	))
}

// ExecuteJavaScript는 fire-and-forget — 결과 회신 없음. 결과 필요 시 JS 측에서
// suji.send(channel, value) 회신.
func ExecuteJavaScript(windowID uint32, code string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"execute_javascript","windowId":%d,"code":"%s"}`,
		windowID, escapeJSON(code),
	))
}

func GetURL(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"get_url","windowId":%d}`, windowID))
}

func IsLoading(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"is_loading","windowId":%d}`, windowID))
}

func OpenDevTools(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"open_dev_tools","windowId":%d}`, windowID))
}
func CloseDevTools(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"close_dev_tools","windowId":%d}`, windowID))
}
func IsDevToolsOpened(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"is_dev_tools_opened","windowId":%d}`, windowID))
}
func ToggleDevTools(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"toggle_dev_tools","windowId":%d}`, windowID))
}

func SetZoomLevel(windowID uint32, level float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"set_zoom_level","windowId":%d,"level":%g}`, windowID, level))
}
func GetZoomLevel(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"get_zoom_level","windowId":%d}`, windowID))
}
func SetZoomFactor(windowID uint32, factor float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"set_zoom_factor","windowId":%d,"factor":%g}`, windowID, factor))
}
func GetZoomFactor(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"get_zoom_factor","windowId":%d}`, windowID))
}

func Undo(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"undo","windowId":%d}`, windowID))
}
func Redo(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"redo","windowId":%d}`, windowID))
}
func Cut(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"cut","windowId":%d}`, windowID))
}
func Copy(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"copy","windowId":%d}`, windowID))
}
func Paste(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"paste","windowId":%d}`, windowID))
}
func SelectAll(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"select_all","windowId":%d}`, windowID))
}

type FindOptions struct {
	Forward   bool
	MatchCase bool
	FindNext  bool
}

func FindInPage(windowID uint32, text string, opts FindOptions) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"find_in_page","windowId":%d,"text":"%s","forward":%t,"matchCase":%t,"findNext":%t}`,
		windowID, escapeJSON(text), opts.Forward, opts.MatchCase, opts.FindNext,
	))
}

func StopFindInPage(windowID uint32, clearSelection bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"stop_find_in_page","windowId":%d,"clearSelection":%t}`,
		windowID, clearSelection,
	))
}

// PrintToPDF는 콜백 async — 결과는 `window:pdf-print-finished` 이벤트.
func PrintToPDF(windowID uint32, path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"print_to_pdf","windowId":%d,"path":"%s"}`,
		windowID, escapeJSON(path),
	))
}

func SetTitle(windowID uint32, title string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"set_title","windowId":%d,"title":"%s"}`,
		windowID, escapeJSON(title),
	))
}

type SetBoundsArgs struct {
	X, Y          int32
	Width, Height uint32
}

func SetBounds(windowID uint32, b SetBoundsArgs) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"set_bounds","windowId":%d,"x":%d,"y":%d,"width":%d,"height":%d}`,
		windowID, b.X, b.Y, b.Width, b.Height,
	))
}

// escapeJSON — `"` `\\` 이스케이프 + control char drop. JSON 리터럴 안전성 보장.
func escapeJSON(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r < 0x20:
			// drop
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}
