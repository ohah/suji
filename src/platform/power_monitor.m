// src/platform/power_monitor.m
//
// Electron `powerMonitor` 동등 — NSWorkspace 알림 옵저버.
//   - NSWorkspaceWillSleepNotification         → "suspend"
//   - NSWorkspaceDidWakeNotification           → "resume"
//   - NSWorkspaceScreensDidSleepNotification   → "lock-screen"
//   - NSWorkspaceScreensDidWakeNotification    → "unlock-screen"
//
// 옵저버는 process-global 1개 + C 콜백으로 dispatch (Zig 측이 EventBus emit).
// Linux/Windows는 power_monitor_linux.c / power_monitor_win.c가 동일 C 콜백 ABI를 제공.

#import <AppKit/AppKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

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

// Electron powerMonitor.isOnBatteryPower() — 현재 전원이 배터리인지(IOKit IOPS).
// IOPSGetProvidingPowerSourceType: "AC Power" | "Battery Power" | "UPS Power".
int suji_power_monitor_is_on_battery(void) {
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob == NULL) return 0;
    CFStringRef type = IOPSGetProvidingPowerSourceType(blob);
    int on_battery = (type != NULL &&
                      CFStringCompare(type, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo)
                         ? 1
                         : 0;
    CFRelease(blob);
    return on_battery;
}
