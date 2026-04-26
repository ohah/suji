// src/platform/window_lifecycle.m
//
// NSWindowDelegate wrapper — resize/focus/blur/move 이벤트를 C 콜백으로 dispatch.
// 모든 Suji NSWindow가 단일 SujiWindowLifecycleDelegate를 공유하고, sender NSWindow*
// → handle 매핑 테이블로 어느 창인지 식별. NSWindow.delegate는 weak reference라
// delegate 자체는 g_delegate에 retain 보관.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#define SUJI_WINDOW_LIFECYCLE_MAX 64

typedef struct {
    void *ns_window;
    uint64_t handle;
} WindowEntry;

static WindowEntry g_windows[SUJI_WINDOW_LIFECYCLE_MAX];
static int g_window_count = 0;

// callback signature: (handle, event_name, x, y, width, height)
//   resized → (h, "resized", frame.x, frame.y, frame.w, frame.h)
//   moved   → (h, "moved",   frame.x, frame.y, 0, 0)
//   focus   → (h, "focus",   0, 0, 0, 0)
//   blur    → (h, "blur",    0, 0, 0, 0)
static void (*g_callback)(uint64_t handle, const char *event, double x, double y, double width, double height) = NULL;

static uint64_t lookup_handle(void *ns_window) {
    for (int i = 0; i < g_window_count; i++) {
        if (g_windows[i].ns_window == ns_window) return g_windows[i].handle;
    }
    return 0;
}

@interface SujiWindowLifecycleDelegate : NSObject<NSWindowDelegate>
@end

@implementation SujiWindowLifecycleDelegate

- (void)windowDidResize:(NSNotification *)note {
    NSWindow *win = note.object;
    uint64_t handle = lookup_handle((__bridge void *)win);
    if (handle == 0 || !g_callback) return;
    NSRect frame = win.frame;
    g_callback(handle, "resized", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
}

- (void)windowDidMove:(NSNotification *)note {
    NSWindow *win = note.object;
    uint64_t handle = lookup_handle((__bridge void *)win);
    if (handle == 0 || !g_callback) return;
    NSRect frame = win.frame;
    g_callback(handle, "moved", frame.origin.x, frame.origin.y, 0, 0);
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    NSWindow *win = note.object;
    uint64_t handle = lookup_handle((__bridge void *)win);
    if (handle == 0 || !g_callback) return;
    g_callback(handle, "focus", 0, 0, 0, 0);
}

- (void)windowDidResignKey:(NSNotification *)note {
    NSWindow *win = note.object;
    uint64_t handle = lookup_handle((__bridge void *)win);
    if (handle == 0 || !g_callback) return;
    g_callback(handle, "blur", 0, 0, 0, 0);
}

@end

static SujiWindowLifecycleDelegate *g_delegate = nil;

void suji_window_lifecycle_set_callback(
    void (*cb)(uint64_t, const char *, double, double, double, double)
) {
    g_callback = cb;
    if (!g_delegate) {
        g_delegate = [[SujiWindowLifecycleDelegate alloc] init];
    }
}

// window 생성 직후 cef.zig가 호출. delegate를 NSWindow에 부착하고 (NSWindow*, handle) 매핑 등록.
// delegate가 이미 다른 윈도우에 부착돼도 NSNotification.object로 sender 식별 가능 → 단일 delegate 공유.
int suji_window_lifecycle_attach(void *ns_window, uint64_t handle) {
    if (ns_window == NULL || g_delegate == nil) return 0;
    if (g_window_count >= SUJI_WINDOW_LIFECYCLE_MAX) return 0;
    // 이미 등록되어 있으면 no-op
    if (lookup_handle(ns_window) != 0) return 1;
    g_windows[g_window_count].ns_window = ns_window;
    g_windows[g_window_count].handle = handle;
    g_window_count++;
    NSWindow *win = (__bridge NSWindow *)ns_window;
    win.delegate = g_delegate;
    return 1;
}

// window 파괴 직전 cef.zig가 호출. 매핑 제거 (delegate는 weak ref라 NSWindow dealloc 시 자동 해제).
void suji_window_lifecycle_detach(void *ns_window) {
    if (ns_window == NULL) return;
    for (int i = 0; i < g_window_count; i++) {
        if (g_windows[i].ns_window == ns_window) {
            for (int j = i; j < g_window_count - 1; j++) {
                g_windows[j] = g_windows[j + 1];
            }
            g_window_count--;
            return;
        }
    }
}
