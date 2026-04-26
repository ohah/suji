// src/platform/window_lifecycle.m
//
// NSWindowDelegate wrapper — resize/focus/blur/move 이벤트를 4개 typed C 콜백으로 dispatch.
// 모든 Suji NSWindow가 단일 SujiWindowLifecycleDelegate를 공유하고 (NSWindow*, handle, last bounds)
// 매핑 테이블로 어느 창인지 식별 + 동일 좌표 중복 emit 차단. NSWindow.delegate는 weak ref라
// delegate 자체는 g_delegate에 retain 보관.
//
// Threading: g_windows / g_window_count / g_*_callback 모두 main thread only 접근.
//   - attach/detach: cef.zig CefNative.createWindow/destroyWindow에서 main thread 호출
//   - delegate methods: NSNotification main run loop dispatch
// 별도 lock 없이 안전.

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
    WindowEntry *e = entry_for_window(note.object);
    if (e == NULL || g_resized_cb == NULL) return;
    NSRect f = ((NSWindow *)note.object).frame;
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

@end

static SujiWindowLifecycleDelegate *g_delegate = nil;

static void ensure_delegate(void) {
    if (g_delegate == nil) g_delegate = [[SujiWindowLifecycleDelegate alloc] init];
}

void suji_window_lifecycle_set_callbacks(
    void (*resized)(uint64_t, double, double, double, double),
    void (*moved)(uint64_t, double, double),
    void (*focus)(uint64_t),
    void (*blur)(uint64_t)
) {
    g_resized_cb = resized;
    g_moved_cb = moved;
    g_focus_cb = focus;
    g_blur_cb = blur;
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
