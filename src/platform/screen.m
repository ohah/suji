// src/platform/screen.m
//
// Electron `screen` display 변경 이벤트 옵저버 — NSApplicationDidChangeScreenParameters
// Notification 을 관찰해 C 콜백으로 dispatch. Zig 측(cef_screen.zig)이 디스플레이 수를
// 비교해 display-added / display-removed / display-metrics-changed 를 EventBus 로 emit.
//
// power_monitor.m 의 옵저버 패턴과 동형(process-global 1개 + C 콜백 ABI).

#import <AppKit/AppKit.h>

static void (*g_screen_callback)(void) = NULL;

@interface SujiScreenObserver : NSObject
@end

@implementation SujiScreenObserver
- (void)onScreenParamsChanged:(NSNotification *)note {
    (void)note;
    if (g_screen_callback) g_screen_callback();
}
@end

static SujiScreenObserver *g_screen_observer = nil;

void suji_screen_install(void (*cb)(void)) {
    g_screen_callback = cb;
    if (g_screen_observer != nil) return;
    g_screen_observer = [[SujiScreenObserver alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:g_screen_observer
                                             selector:@selector(onScreenParamsChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
}

void suji_screen_uninstall(void) {
    if (g_screen_observer == nil) return;
    [[NSNotificationCenter defaultCenter] removeObserver:g_screen_observer];
    g_screen_observer = nil;
    g_screen_callback = NULL;
}
