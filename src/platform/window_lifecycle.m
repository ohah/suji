// src/platform/window_lifecycle.m
//
// NSWindowDelegate wrapper — resize/focus/blur/move + minimize/restore/maximize/
// unmaximize/enter-full-screen/leave-full-screen 이벤트를 typed C 콜백으로 dispatch.
// 모든 Suji NSWindow가 단일 SujiWindowLifecycleDelegate를 공유하고 (NSWindow*, handle, last bounds)
// 매핑 테이블로 어느 창인지 식별 + 동일 좌표 중복 emit 차단. NSWindow.delegate는 weak ref라
// delegate 자체는 g_delegate에 retain 보관.
//
// Threading: g_windows / g_window_count / g_*_callback 모두 main thread only 접근.
//   - attach/detach: cef.zig CefNative.createWindow/destroyWindow에서 main thread 호출
//   - delegate methods: NSNotification main run loop dispatch
// 별도 lock 없이 안전.
//
// maximize/unmaximize는 NSWindow에 zoom 완료 delegate가 없어(`windowShouldZoom:toFrame:`만 존재)
// `suji_window_lifecycle_maximize/unmaximize` API 호출 시점에 직접 emit. macOS 11+에서
// traffic light green = fullscreen으로 매핑되어 legacy zoom 경로는 사실상 미사용.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#define SUJI_WINDOW_LIFECYCLE_MAX 64

typedef struct {
    void *ns_window;
    uint64_t handle;
    // 마지막 emit한 frame — 동일 값 중복 emit 차단 (60Hz drag 중 mouse hold 시 효과적).
    double last_x;
    double last_y;
    double last_width;
    double last_height;
    BOOL has_last;
} WindowEntry;

static WindowEntry g_windows[SUJI_WINDOW_LIFECYCLE_MAX];
static int g_window_count = 0;

static void (*g_resized_cb)(uint64_t handle, double x, double y, double width, double height) = NULL;
static void (*g_moved_cb)(uint64_t handle, double x, double y) = NULL;
static void (*g_focus_cb)(uint64_t handle) = NULL;
static void (*g_blur_cb)(uint64_t handle) = NULL;
static void (*g_minimize_cb)(uint64_t handle) = NULL;
static void (*g_restore_cb)(uint64_t handle) = NULL;
static void (*g_maximize_cb)(uint64_t handle) = NULL;
static void (*g_unmaximize_cb)(uint64_t handle) = NULL;
static void (*g_enter_fullscreen_cb)(uint64_t handle) = NULL;
static void (*g_leave_fullscreen_cb)(uint64_t handle) = NULL;
/// will_resize는 동기 — handler가 proposed in-out 변경하면 그 값이 실제 size.
/// listener가 preventDefault → handler가 proposed를 curr로 덮어쓰면 NSWindow가 그 크기로 resize.
static void (*g_will_resize_cb)(uint64_t handle, double curr_w, double curr_h, double *proposed_w, double *proposed_h) = NULL;

static WindowEntry *entry_for_window(NSWindow *win) {
    void *ptr = (__bridge void *)win;
    for (int i = 0; i < g_window_count; i++) {
        if (g_windows[i].ns_window == ptr) return &g_windows[i];
    }
    return NULL;
}

@interface SujiWindowLifecycleDelegate : NSObject<NSWindowDelegate>
@end

@implementation SujiWindowLifecycleDelegate

- (void)windowDidResize:(NSNotification *)note {
    NSWindow *win = note.object;
    WindowEntry *e = entry_for_window(win);
    if (e == NULL || g_resized_cb == NULL) return;
    NSRect f = win.frame;
    if (e->has_last && e->last_x == f.origin.x && e->last_y == f.origin.y &&
        e->last_width == f.size.width && e->last_height == f.size.height) return;
    e->last_x = f.origin.x; e->last_y = f.origin.y;
    e->last_width = f.size.width; e->last_height = f.size.height;
    e->has_last = YES;
    g_resized_cb(e->handle, f.origin.x, f.origin.y, f.size.width, f.size.height);
}

- (void)windowDidMove:(NSNotification *)note {
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_moved_cb == NULL) return;
    NSRect f = ((NSWindow *)note.object).frame;
    // origin만 변경된 케이스에 한해 emit (size 동시 변경은 windowDidResize가 처리).
    if (e->has_last && e->last_x == f.origin.x && e->last_y == f.origin.y) return;
    e->last_x = f.origin.x; e->last_y = f.origin.y;
    e->last_width = f.size.width; e->last_height = f.size.height;
    e->has_last = YES;
    g_moved_cb(e->handle, f.origin.x, f.origin.y);
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_focus_cb == NULL) return;
    g_focus_cb(e->handle);
}

- (void)windowDidResignKey:(NSNotification *)note {
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_blur_cb == NULL) return;
    g_blur_cb(e->handle);
}

- (void)windowDidMiniaturize:(NSNotification *)note {
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_minimize_cb == NULL) return;
    g_minimize_cb(e->handle);
}

- (void)windowDidDeminiaturize:(NSNotification *)note {
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_restore_cb == NULL) return;
    g_restore_cb(e->handle);
}

- (void)windowDidEnterFullScreen:(NSNotification *)note {
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_enter_fullscreen_cb == NULL) return;
    g_enter_fullscreen_cb(e->handle);
}

- (void)windowDidExitFullScreen:(NSNotification *)note {
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_leave_fullscreen_cb == NULL) return;
    g_leave_fullscreen_cb(e->handle);
}

/// 사용자/native가 NSWindow 크기 변경을 시도할 때 동기 호출 — 반환값이 실제 크기.
/// 핸들러가 in-out 포인터를 통해 proposed를 mutate 가능 (preventDefault → curr로 복원).
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
    WindowEntry *e = entry_for_window(sender);
    if (e == NULL || g_will_resize_cb == NULL) return frameSize;
    NSSize curr = [sender frame].size;
    double proposed_w = frameSize.width;
    double proposed_h = frameSize.height;
    g_will_resize_cb(e->handle, curr.width, curr.height, &proposed_w, &proposed_h);
    return NSMakeSize(proposed_w, proposed_h);
}

@end

static SujiWindowLifecycleDelegate *g_delegate = nil;

static void ensure_delegate(void) {
    if (g_delegate == nil) g_delegate = [[SujiWindowLifecycleDelegate alloc] init];
}

/// 11개 콜백을 한 struct로 — 6개가 동일 시그니처 `void(uint64_t)`라 위치 기반 인자
/// 전달 시 silent mis-routing(예: minimize 자리에 maximize 함수)을 컴파일 타임에 차단.
typedef struct {
    void (*resized)(uint64_t, double, double, double, double);
    void (*moved)(uint64_t, double, double);
    void (*focus)(uint64_t);
    void (*blur)(uint64_t);
    void (*minimize)(uint64_t);
    void (*restore)(uint64_t);
    void (*maximize)(uint64_t);
    void (*unmaximize)(uint64_t);
    void (*enter_fullscreen)(uint64_t);
    void (*leave_fullscreen)(uint64_t);
    void (*will_resize)(uint64_t, double, double, double *, double *);
} suji_window_lifecycle_callbacks_t;

void suji_window_lifecycle_set_callbacks(const suji_window_lifecycle_callbacks_t *cbs) {
    if (cbs == NULL) return;
    g_resized_cb = cbs->resized;
    g_moved_cb = cbs->moved;
    g_focus_cb = cbs->focus;
    g_blur_cb = cbs->blur;
    g_minimize_cb = cbs->minimize;
    g_restore_cb = cbs->restore;
    g_maximize_cb = cbs->maximize;
    g_unmaximize_cb = cbs->unmaximize;
    g_enter_fullscreen_cb = cbs->enter_fullscreen;
    g_leave_fullscreen_cb = cbs->leave_fullscreen;
    g_will_resize_cb = cbs->will_resize;
    ensure_delegate();
}

int suji_window_lifecycle_attach(void *ns_window, uint64_t handle) {
    if (ns_window == NULL) return 0;
    if (g_window_count >= SUJI_WINDOW_LIFECYCLE_MAX) return 0;
    ensure_delegate();
    if (g_delegate == nil) return 0;
    for (int i = 0; i < g_window_count; i++) {
        if (g_windows[i].ns_window == ns_window) return 1;
    }
    WindowEntry *e = &g_windows[g_window_count++];
    e->ns_window = ns_window;
    e->handle = handle;
    e->has_last = NO;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    // toggleFullScreen이 동작하려면 collectionBehavior에 FullScreenPrimary 비트 필수.
    // CEF 기본 NSWindow는 0x0 — set 안 하면 toggleFullScreen은 no-op.
    [win setCollectionBehavior:[win collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary];
    win.delegate = g_delegate;
    return 1;
}

void suji_window_lifecycle_detach(void *ns_window) {
    if (ns_window == NULL) return;
    for (int i = 0; i < g_window_count; i++) {
        if (g_windows[i].ns_window == ns_window) {
            for (int j = i; j < g_window_count - 1; j++) g_windows[j] = g_windows[j + 1];
            g_window_count--;
            return;
        }
    }
}

// ============================================
// 윈도우 상태 제어 API — Zig WM의 minimize/restore/maximize/unmaximize/setFullScreen 위임.
// 각 함수는 main thread에서 호출되어야 함 (NSWindow는 main-thread only).
// ============================================

void suji_window_lifecycle_minimize(void *ns_window) {
    if (ns_window == NULL) return;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    [win miniaturize:nil];
}

void suji_window_lifecycle_deminiaturize(void *ns_window) {
    if (ns_window == NULL) return;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    [win deminiaturize:nil];
}

/// `[win zoom:]`은 NSWindowDelegate에 zoom 완료 메서드가 없어 (`windowShouldZoom:toFrame:`만
/// 존재) windowDidResize 기반 검출은 in_live_resize/애니메이션 race로 신뢰 불가. API 호출
/// 시점에 직접 cb 발화. traffic light green = macOS 11+에서 fullscreen으로 매핑되어 legacy
/// zoom 경로는 사실상 미사용 (Option-click legacy zoom은 미커버 — Phase 5 scope 외).
void suji_window_lifecycle_maximize(void *ns_window) {
    if (ns_window == NULL) return;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    if ([win isZoomed]) return;
    [win zoom:nil];
    WindowEntry *e = entry_for_window(win);
    if (e == NULL) return;
    if (g_maximize_cb) g_maximize_cb(e->handle);
}

void suji_window_lifecycle_unmaximize(void *ns_window) {
    if (ns_window == NULL) return;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    if (![win isZoomed]) return;
    [win zoom:nil];
    WindowEntry *e = entry_for_window(win);
    if (e == NULL) return;
    if (g_unmaximize_cb) g_unmaximize_cb(e->handle);
}

/// `[win toggleFullScreen:]`도 toggle이라 사전 검사로 멱등 보장.
void suji_window_lifecycle_set_fullscreen(void *ns_window, int flag) {
    if (ns_window == NULL) return;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    BOOL is_fs = ([win styleMask] & NSWindowStyleMaskFullScreen) != 0;
    BOOL want = flag != 0;
    if (is_fs == want) return;
    // toggleFullScreen은 key window 상태에서만 안정 동작 — 새 창이 background일 때
    // makeKeyAndOrderFront로 활성화 후 toggle. NSApp activationPolicy=Regular이면 가능.
    [win makeKeyAndOrderFront:nil];
    [win toggleFullScreen:nil];
}

int suji_window_lifecycle_is_minimized(void *ns_window) {
    if (ns_window == NULL) return 0;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    return [win isMiniaturized] ? 1 : 0;
}

int suji_window_lifecycle_is_maximized(void *ns_window) {
    if (ns_window == NULL) return 0;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    return [win isZoomed] ? 1 : 0;
}

int suji_window_lifecycle_is_fullscreen(void *ns_window) {
    if (ns_window == NULL) return 0;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    return ([win styleMask] & NSWindowStyleMaskFullScreen) != 0 ? 1 : 0;
}
