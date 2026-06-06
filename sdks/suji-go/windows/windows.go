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

// PrintToPDF — 코어가 CDP 완료까지 응답 보류 → 응답 JSON 에 `success` 직접 포함
// (예: `{"from":"zig-core","cmd":"print_to_pdf","path":"...","success":true}`).
// EventBus emit `window:pdf-print-finished` 도 동시 발화(다른 구독자 호환).
func PrintToPDF(windowID uint32, path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"print_to_pdf","windowId":%d,"path":"%s"}`,
		windowID, jsonesc.Full(path),
	))
}

// CapturePage — 페이지 스크린샷 PNG 저장 (Electron webContents.capturePage,
// CDP Page.captureScreenshot). 코어 deferred response — 응답 JSON 에 `success`
// 직접 포함. EventBus emit `window:page-captured` 도 동시 발화.
func CapturePage(windowID uint32, path string) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"capture_page","windowId":%d,"path":"%s"}`,
		windowID, jsonesc.Full(path),
	))
}

// CapturePageRect — 부분 영역 스크린샷 (Electron webContents.capturePage(rect)).
// CSS px. Go 는 기본인자 없음 → CapturePage 와 별도 fn(무회귀).
func CapturePageRect(windowID uint32, path string, x, y, width, height int) string {
	return suji.Invoke("__core__", fmt.Sprintf(
		`{"cmd":"capture_page","windowId":%d,"path":"%s","clipX":%d,"clipY":%d,"clipWidth":%d,"clipHeight":%d}`,
		windowID, jsonesc.Full(path), x, y, width, height,
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

type CreateViewArgs struct {
	HostID uint32
	Name   string
	URL    string
	Bounds SetBoundsArgs
}

func CreateView(args CreateViewArgs) string {
	return suji.Invoke("__core__", createViewRequest(args))
}

func DestroyView(viewID uint32) string {
	return suji.Invoke("__core__", destroyViewRequest(viewID))
}

func AddChildView(hostID, viewID uint32, index ...uint32) string {
	return suji.Invoke("__core__", addChildViewRequest(hostID, viewID, index...))
}

func RemoveChildView(hostID, viewID uint32) string {
	return suji.Invoke("__core__", removeChildViewRequest(hostID, viewID))
}

func SetTopView(hostID, viewID uint32) string {
	return suji.Invoke("__core__", setTopViewRequest(hostID, viewID))
}

func SetViewBounds(viewID uint32, b SetBoundsArgs) string {
	return suji.Invoke("__core__", setViewBoundsRequest(viewID, b))
}

func SetViewVisible(viewID uint32, visible bool) string {
	return suji.Invoke("__core__", setViewVisibleRequest(viewID, visible))
}

func GetChildViews(hostID uint32) string {
	return suji.Invoke("__core__", getChildViewsRequest(hostID))
}

func createViewRequest(args CreateViewArgs) string {
	req := fmt.Sprintf(`{"cmd":"create_view","hostId":%d`, args.HostID)
	if args.Name != "" {
		req += fmt.Sprintf(`,"name":"%s"`, jsonesc.Full(args.Name))
	}
	if args.URL != "" {
		req += fmt.Sprintf(`,"url":"%s"`, jsonesc.Full(args.URL))
	}
	req += fmt.Sprintf(
		`,"x":%d,"y":%d,"width":%d,"height":%d}`,
		args.Bounds.X, args.Bounds.Y, args.Bounds.Width, args.Bounds.Height,
	)
	return req
}

func addChildViewRequest(hostID, viewID uint32, index ...uint32) string {
	req := fmt.Sprintf(`{"cmd":"add_child_view","hostId":%d,"viewId":%d`, hostID, viewID)
	if len(index) > 0 {
		req += fmt.Sprintf(`,"index":%d`, index[0])
	}
	return req + "}"
}

func destroyViewRequest(viewID uint32) string {
	return fmt.Sprintf(`{"cmd":"destroy_view","viewId":%d}`, viewID)
}

func removeChildViewRequest(hostID, viewID uint32) string {
	return fmt.Sprintf(`{"cmd":"remove_child_view","hostId":%d,"viewId":%d}`, hostID, viewID)
}

func setTopViewRequest(hostID, viewID uint32) string {
	return fmt.Sprintf(`{"cmd":"set_top_view","hostId":%d,"viewId":%d}`, hostID, viewID)
}

func setViewBoundsRequest(viewID uint32, b SetBoundsArgs) string {
	return fmt.Sprintf(
		`{"cmd":"set_view_bounds","viewId":%d,"x":%d,"y":%d,"width":%d,"height":%d}`,
		viewID, b.X, b.Y, b.Width, b.Height,
	)
}

func setViewVisibleRequest(viewID uint32, visible bool) string {
	return fmt.Sprintf(`{"cmd":"set_view_visible","viewId":%d,"visible":%t}`, viewID, visible)
}

func getChildViewsRequest(hostID uint32) string {
	return fmt.Sprintf(`{"cmd":"get_child_views","hostId":%d}`, hostID)
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

// ── Electron BrowserWindow 생명주기/상태 (JS @suji/api 패리티) ──
// 대부분 {"cmd":"X","windowId":N} 동형 → windowOpRequest 로 DRY. 응답은 raw JSON.
func windowOpRequest(cmd string, windowID uint32) string {
	return fmt.Sprintf(`{"cmd":"%s","windowId":%d}`, cmd, windowID)
}
func setVisibleRequest(windowID uint32, visible bool) string {
	return fmt.Sprintf(`{"cmd":"set_visible","windowId":%d,"visible":%t}`, windowID, visible)
}
func setFullscreenRequest(windowID uint32, flag bool) string {
	return fmt.Sprintf(`{"cmd":"set_fullscreen","windowId":%d,"flag":%t}`, windowID, flag)
}
func setAlwaysOnTopRequest(windowID uint32, onTop bool) string {
	return fmt.Sprintf(`{"cmd":"set_always_on_top","windowId":%d,"onTop":%t}`, windowID, onTop)
}

func Minimize(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("minimize", windowID))
}
func Maximize(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("maximize", windowID))
}
func Unmaximize(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("unmaximize", windowID))
}
func Restore(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("restore_window", windowID))
}
func Close(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("destroy_window", windowID))
}
func Show(windowID uint32) string { return suji.Invoke("__core__", setVisibleRequest(windowID, true)) }
func Hide(windowID uint32) string { return suji.Invoke("__core__", setVisibleRequest(windowID, false)) }
func SetFullScreen(windowID uint32, flag bool) string {
	return suji.Invoke("__core__", setFullscreenRequest(windowID, flag))
}
func IsMinimized(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("is_minimized", windowID))
}
func IsMaximized(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("is_maximized", windowID))
}
func IsFullScreen(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("is_fullscreen", windowID))
}
func IsNormal(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("is_normal", windowID))
}
func Focus(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("focus", windowID))
}
func Blur(windowID uint32) string { return suji.Invoke("__core__", windowOpRequest("blur", windowID)) }
func IsFocused(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("is_focused", windowID))
}
func IsVisible(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("is_visible", windowID))
}
func GetBounds(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("get_bounds", windowID))
}
func SetAlwaysOnTop(windowID uint32, onTop bool) string {
	return suji.Invoke("__core__", setAlwaysOnTopRequest(windowID, onTop))
}
func IsAlwaysOnTop(windowID uint32) string {
	return suji.Invoke("__core__", windowOpRequest("is_always_on_top", windowID))
}
func GetAllWindows() string    { return suji.Invoke("__core__", `{"cmd":"get_all_windows"}`) }
func GetFocusedWindow() string { return suji.Invoke("__core__", `{"cmd":"get_focused_window"}`) }

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
func (w *BrowserWindow) CapturePageRect(path string, x, y, width, height int) string {
	return CapturePageRect(w.ID, path, x, y, width, height)
}
func (w *BrowserWindow) SetTitle(title string) string { return SetTitle(w.ID, title) }
func (w *BrowserWindow) SetBounds(b SetBoundsArgs) string {
	return SetBounds(w.ID, b)
}
func (w *BrowserWindow) CreateView(args CreateViewArgs) string {
	args.HostID = w.ID
	return CreateView(args)
}
func (w *BrowserWindow) DestroyView(viewID uint32) string { return DestroyView(viewID) }
func (w *BrowserWindow) AddChildView(viewID uint32, index ...uint32) string {
	return AddChildView(w.ID, viewID, index...)
}
func (w *BrowserWindow) RemoveChildView(viewID uint32) string { return RemoveChildView(w.ID, viewID) }
func (w *BrowserWindow) SetTopView(viewID uint32) string      { return SetTopView(w.ID, viewID) }
func (w *BrowserWindow) SetViewBounds(viewID uint32, b SetBoundsArgs) string {
	return SetViewBounds(viewID, b)
}
func (w *BrowserWindow) SetViewVisible(viewID uint32, visible bool) string {
	return SetViewVisible(viewID, visible)
}
func (w *BrowserWindow) GetChildViews() string { return GetChildViews(w.ID) }

// Electron BrowserWindow 생명주기/상태 (JS @suji/api 패리티).
func (w *BrowserWindow) Minimize() string                 { return Minimize(w.ID) }
func (w *BrowserWindow) Maximize() string                 { return Maximize(w.ID) }
func (w *BrowserWindow) Unmaximize() string               { return Unmaximize(w.ID) }
func (w *BrowserWindow) Restore() string                  { return Restore(w.ID) }
func (w *BrowserWindow) Close() string                    { return Close(w.ID) }
func (w *BrowserWindow) Show() string                     { return Show(w.ID) }
func (w *BrowserWindow) Hide() string                     { return Hide(w.ID) }
func (w *BrowserWindow) SetFullScreen(flag bool) string   { return SetFullScreen(w.ID, flag) }
func (w *BrowserWindow) IsMinimized() string              { return IsMinimized(w.ID) }
func (w *BrowserWindow) IsMaximized() string              { return IsMaximized(w.ID) }
func (w *BrowserWindow) IsFullScreen() string             { return IsFullScreen(w.ID) }
func (w *BrowserWindow) IsNormal() string                 { return IsNormal(w.ID) }
func (w *BrowserWindow) Focus() string                    { return Focus(w.ID) }
func (w *BrowserWindow) Blur() string                     { return Blur(w.ID) }
func (w *BrowserWindow) IsFocused() string                { return IsFocused(w.ID) }
func (w *BrowserWindow) IsVisible() string                { return IsVisible(w.ID) }
func (w *BrowserWindow) GetBounds() string                { return GetBounds(w.ID) }
func (w *BrowserWindow) SetAlwaysOnTop(onTop bool) string { return SetAlwaysOnTop(w.ID, onTop) }
func (w *BrowserWindow) IsAlwaysOnTop() string            { return IsAlwaysOnTop(w.ID) }
