// Package windows provides Suji webContents API (Phase 4-A) — 창 네비게이션,
// JS 실행, 상태 조회. Frontend `@suji/api`의 windows.* 와 같은 cmd JSON 형식.
//
// dlopen 환경에선 in-process 코어 접근 불가 → 모두 suji.Invoke("__core__", ...) 경유.
package windows

import (
	"encoding/json"
	"fmt"

	suji "github.com/ohah/suji-go"
	"github.com/ohah/suji-go/internal/jsonesc"
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
	opts := fmt.Sprintf(`"title":"%s","url":"%s"`, jsonesc.Full(title), jsonesc.Full(url))
	return Create(opts)
}

func LoadURL(windowID uint32, url string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"load_url","windowId":%d,"url":"%s"}`,
		windowID, jsonesc.Full(url),
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
		windowID, jsonesc.Full(code),
	))
}

func GetURL(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"get_url","windowId":%d}`, windowID))
}

// SetUserAgent — UA 동적 변경 (Electron webContents.setUserAgent, CDP override).
func SetUserAgent(windowID uint32, userAgent string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"set_user_agent","windowId":%d,"userAgent":"%s"}`,
		windowID, jsonesc.Full(userAgent),
	))
}

// GetUserAgent — 설정한 UA override 조회. 미설정 시 응답 userAgent=null.
func GetUserAgent(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"get_user_agent","windowId":%d}`, windowID))
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

// SetAudioMuted toggles window audio mute (Electron `webContents.setAudioMuted`).
func SetAudioMuted(windowID uint32, muted bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"set_audio_muted","windowId":%d,"muted":%t}`, windowID, muted))
}

// IsAudioMuted returns mute state. Response: `{"muted":bool,"ok":bool}`.
func IsAudioMuted(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"is_audio_muted","windowId":%d}`, windowID))
}

// SetOpacity sets window alpha (0~1). Electron `BrowserWindow.setOpacity`.
func SetOpacity(windowID uint32, opacity float64) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"set_opacity","windowId":%d,"opacity":%g}`, windowID, opacity))
}

// GetOpacity returns alpha. Response: `{"opacity":f64,"ok":bool}`.
func GetOpacity(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"get_opacity","windowId":%d}`, windowID))
}

// SetBackgroundColor accepts `#RRGGBB` or `#RRGGBBAA`.
func SetBackgroundColor(windowID uint32, color string) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"set_background_color","windowId":%d,"color":"%s"}`, windowID, jsonesc.Full(color)))
}

// SetHasShadow toggles window shadow. Response: windowOp.
func SetHasShadow(windowID uint32, has bool) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"set_has_shadow","windowId":%d,"hasShadow":%t}`, windowID, has))
}

// HasShadow returns shadow state. Response: `{"hasShadow":bool,"ok":bool}`.
func HasShadow(windowID uint32) string {
	return suji.Invoke("__core__", fmt.Sprintf(`{"cmd":"has_shadow","windowId":%d}`, windowID))
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
		windowID, jsonesc.Full(text), opts.Forward, opts.MatchCase, opts.FindNext,
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
		windowID, jsonesc.Full(path),
	))
}

// CapturePage — 페이지 스크린샷 PNG 저장 (Electron webContents.capturePage,
// CDP Page.captureScreenshot). 즉시 ack + 완료는 window:page-captured
// 이벤트({path,success}) — caller 가 on 으로 path 매칭(PrintToPDF 동형).
func CapturePage(windowID uint32, path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"capture_page","windowId":%d,"path":"%s"}`,
		windowID, jsonesc.Full(path),
	))
}

func SetTitle(windowID uint32, title string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"set_title","windowId":%d,"title":"%s"}`,
		windowID, jsonesc.Full(title),
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

// parseWindowID — create 응답 JSON 에서 windowId 추출 (순수 — 테스트 가능).
// 포인터로 키 *존재* 검사 — 부재 시 error (id 0 정상값과 구별, Rust
// parse_window_id 의 None 과 시맨틱 일치).
func parseWindowID(raw string) (uint32, error) {
	var v struct {
		WindowID *uint32 `json:"windowId"`
	}
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		return 0, err
	}
	if v.WindowID == nil {
		return 0, fmt.Errorf("response has no windowId: %s", raw)
	}
	return *v.WindowID, nil
}

// BrowserWindow — windows.*(raw windowID)의 객체지향 facade (Electron
// `BrowserWindow` 패리티, @suji/api 와 동형). 각 메서드는 <Fn>(w.ID, ...)
// 위임 — 로직 무중복, windows 변경에 자동 동기화.
type BrowserWindow struct{ ID uint32 }

// NewBrowserWindow 새 창 생성 후 인스턴스 반환 (Electron new BrowserWindow).
func NewBrowserWindow(optsJSON string) (*BrowserWindow, error) {
	id, err := parseWindowID(Create(optsJSON))
	if err != nil {
		return nil, err
	}
	return &BrowserWindow{ID: id}, nil
}

// FromID 기존 windowID(메인 창/이벤트 sender)를 인스턴스로 래핑.
func FromID(id uint32) *BrowserWindow { return &BrowserWindow{ID: id} }

func (w *BrowserWindow) LoadURL(url string) string { return LoadURL(w.ID, url) }
func (w *BrowserWindow) Reload(ignoreCache bool) string {
	return Reload(w.ID, ignoreCache)
}
func (w *BrowserWindow) ExecuteJavaScript(code string) string {
	return ExecuteJavaScript(w.ID, code)
}
func (w *BrowserWindow) GetURL() string { return GetURL(w.ID) }
func (w *BrowserWindow) SetUserAgent(ua string) string {
	return SetUserAgent(w.ID, ua)
}
func (w *BrowserWindow) GetUserAgent() string           { return GetUserAgent(w.ID) }
func (w *BrowserWindow) IsLoading() string              { return IsLoading(w.ID) }
func (w *BrowserWindow) OpenDevTools() string           { return OpenDevTools(w.ID) }
func (w *BrowserWindow) CloseDevTools() string          { return CloseDevTools(w.ID) }
func (w *BrowserWindow) IsDevToolsOpened() string       { return IsDevToolsOpened(w.ID) }
func (w *BrowserWindow) ToggleDevTools() string         { return ToggleDevTools(w.ID) }
func (w *BrowserWindow) SetZoomLevel(l float64) string  { return SetZoomLevel(w.ID, l) }
func (w *BrowserWindow) GetZoomLevel() string           { return GetZoomLevel(w.ID) }
func (w *BrowserWindow) SetZoomFactor(f float64) string { return SetZoomFactor(w.ID, f) }
func (w *BrowserWindow) GetZoomFactor() string          { return GetZoomFactor(w.ID) }
func (w *BrowserWindow) SetAudioMuted(m bool) string    { return SetAudioMuted(w.ID, m) }
func (w *BrowserWindow) IsAudioMuted() string           { return IsAudioMuted(w.ID) }
func (w *BrowserWindow) SetOpacity(o float64) string    { return SetOpacity(w.ID, o) }
func (w *BrowserWindow) GetOpacity() string             { return GetOpacity(w.ID) }
func (w *BrowserWindow) SetBackgroundColor(c string) string {
	return SetBackgroundColor(w.ID, c)
}
func (w *BrowserWindow) SetHasShadow(h bool) string { return SetHasShadow(w.ID, h) }
func (w *BrowserWindow) HasShadow() string          { return HasShadow(w.ID) }
func (w *BrowserWindow) Undo() string               { return Undo(w.ID) }
func (w *BrowserWindow) Redo() string               { return Redo(w.ID) }
func (w *BrowserWindow) Cut() string                { return Cut(w.ID) }
func (w *BrowserWindow) Copy() string               { return Copy(w.ID) }
func (w *BrowserWindow) Paste() string              { return Paste(w.ID) }
func (w *BrowserWindow) SelectAll() string          { return SelectAll(w.ID) }
func (w *BrowserWindow) FindInPage(text string, opts FindOptions) string {
	return FindInPage(w.ID, text, opts)
}
func (w *BrowserWindow) StopFindInPage(clear bool) string {
	return StopFindInPage(w.ID, clear)
}
func (w *BrowserWindow) PrintToPDF(path string) string { return PrintToPDF(w.ID, path) }
func (w *BrowserWindow) CapturePage(path string) string {
	return CapturePage(w.ID, path)
}
func (w *BrowserWindow) SetTitle(title string) string { return SetTitle(w.ID, title) }
func (w *BrowserWindow) SetBounds(b SetBoundsArgs) string {
	return SetBounds(w.ID, b)
}
