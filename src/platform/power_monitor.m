// src/platform/power_monitor.m
//
// Electron `powerMonitor` 동등 — NSWorkspace 알림 옵저버.
//   - NSWorkspaceWillSleepNotification         → "suspend"
//   - NSWorkspaceDidWakeNotification           → "resume"
//   - NSWorkspaceScreensDidSleepNotification   → "lock-screen"
//   - NSWorkspaceScreensDidWakeNotification    → "unlock-screen"
//
// 옵저버는 process-global 1개 + C 콜백으로 dispatch (Zig 측이 EventBus emit).
// Linux/Windows는 후속.

#import <AppKit/AppKit.h>

static void (*g_power_callback)(const char *event) = NULL;

@interface SujiPowerObserver : NSObject
@end

@implementation SujiPowerObserver
- (void)onSleep:(NSNotification *)note {
    (void)note;
    if (g_power_callback) g_power_callback("suspend");
}
- (void)onWake:(NSNotification *)note {
    (void)note;
    if (g_power_callback) g_power_callback("resume");
}
- (void)onScreenSleep:(NSNotification *)note {
    (void)note;
    if (g_power_callback) g_power_callback("lock-screen");
}
- (void)onScreenWake:(NSNotification *)note {
    (void)note;
    if (g_power_callback) g_power_callback("unlock-screen");
}
@end

static SujiPowerObserver *g_observer = nil;

void suji_power_monitor_install(void (*cb)(const char *)) {
    g_power_callback = cb;
    if (g_observer != nil) return;
    g_observer = [[SujiPowerObserver alloc] init];
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:g_observer selector:@selector(onSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:g_observer selector:@selector(onWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:g_observer selector:@selector(onScreenSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [nc addObserver:g_observer selector:@selector(onScreenWake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
}

void suji_power_monitor_uninstall(void) {
    if (g_observer == nil) return;
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc removeObserver:g_observer];
    g_observer = nil;
    g_power_callback = NULL;
}
