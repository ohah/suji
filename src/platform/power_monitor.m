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
- (void)onPowerOff:(NSNotification *)note {
    (void)note;
    if (g_power_callback) g_power_callback("shutdown");
}
@end

static SujiPowerObserver *g_observer = nil;
static CFRunLoopSourceRef g_power_source = NULL;
static int g_last_on_battery = -1;

int suji_power_monitor_is_on_battery(void); // 아래 정의 — power_source_changed 가 먼저 참조.

// IOPS power-source 변경 콜백 — AC↔배터리 전환 시에만 emit(스풀리어스 중복 억제).
static void power_source_changed(void *ctx) {
    (void)ctx;
    int ob = suji_power_monitor_is_on_battery();
    if (ob == g_last_on_battery) return;
    g_last_on_battery = ob;
    if (g_power_callback) g_power_callback(ob ? "on-battery" : "on-ac");
}

void suji_power_monitor_install(void (*cb)(const char *)) {
    g_power_callback = cb;
    if (g_observer != nil) return;
    g_observer = [[SujiPowerObserver alloc] init];
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:g_observer selector:@selector(onSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:g_observer selector:@selector(onWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:g_observer selector:@selector(onScreenSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [nc addObserver:g_observer selector:@selector(onScreenWake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [nc addObserver:g_observer selector:@selector(onPowerOff:) name:NSWorkspaceWillPowerOffNotification object:nil];

    // IOPS run-loop source — AC/배터리 전환 이벤트(on-battery/on-ac). 메인 런루프에 부착.
    g_last_on_battery = suji_power_monitor_is_on_battery();
    g_power_source = IOPSNotificationCreateRunLoopSource(power_source_changed, NULL);
    if (g_power_source) CFRunLoopAddSource(CFRunLoopGetMain(), g_power_source, kCFRunLoopDefaultMode);
}

void suji_power_monitor_uninstall(void) {
    if (g_observer == nil) return;
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc removeObserver:g_observer];
    g_observer = nil;
    g_power_callback = NULL;
    if (g_power_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), g_power_source, kCFRunLoopDefaultMode);
        CFRelease(g_power_source);
        g_power_source = NULL;
    }
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

// 열 상태 (Electron powerMonitor.getCurrentThermalState). NSProcessInfo.thermalState:
// 0=nominal 1=fair 2=serious 3=critical. macOS 10.10.3+; 미만/조회불가는 -1(unknown).
int suji_power_monitor_thermal_state(void) {
    if (@available(macOS 10.10.3, *)) {
        return (int)[[NSProcessInfo processInfo] thermalState];
    }
    return -1;
}
