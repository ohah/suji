// src/platform/nativetheme.m
//
// Electron `nativeTheme.on('updated', ...)` 동등 — NSApp.effectiveAppearance KVO.
// 시스템 다크/라이트 전환 또는 setThemeSource로 NSApp.appearance 변경 시 발화.
//
// 옵저버는 process-global 1개 + C 콜백으로 dispatch (Zig가 EventBus emit).

#import <AppKit/AppKit.h>

static void (*g_theme_callback)(void) = NULL;

@interface SujiThemeObserver : NSObject
@end

@implementation SujiThemeObserver
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    (void)keyPath;
    (void)object;
    (void)change;
    (void)context;
    if (g_theme_callback) g_theme_callback();
}
@end

static SujiThemeObserver *g_observer = nil;

void suji_native_theme_install(void (*cb)(void)) {
    g_theme_callback = cb;
    if (g_observer != nil) return;
    // NSApp 매크로는 [NSApplication sharedApplication] 호출 전에 nil. 명시적으로 호출해 보장.
    NSApplication *app = [NSApplication sharedApplication];
    g_observer = [[SujiThemeObserver alloc] init];
    [app addObserver:g_observer
          forKeyPath:@"effectiveAppearance"
             options:0
             context:NULL];
}

void suji_native_theme_uninstall(void) {
    if (g_observer == nil) return;
    NSApplication *app = [NSApplication sharedApplication];
    @try {
        [app removeObserver:g_observer forKeyPath:@"effectiveAppearance"];
    } @catch (NSException *e) {
        (void)e;
    }
    g_observer = nil;
    g_theme_callback = NULL;
}
