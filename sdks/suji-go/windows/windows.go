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

// ── Phase 4-C: DevTools ──

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
