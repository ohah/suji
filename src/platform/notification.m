// src/platform/notification.m
//
// UNUserNotificationCenter wrapper (macOS 10.14+, NSUserNotification 대체).
// Zig는 ObjC block(^)을 직접 못 만들어서 권한 요청 + add request의 completion handler를
// 이 파일이 wrap. SujiNotificationDelegate가 click 이벤트를 C 콜백으로 라우팅.
//
// 한계: UNUserNotificationCenter는 valid Bundle ID + Info.plist 필요. `suji dev`처럼
// loose binary로 띄우면 권한 요청 자체가 실패하거나 알림이 안 뜰 수 있음. `suji build`
// 후 .app 번들에서 정상 동작.

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <AppKit/AppKit.h>

// click 콜백 — Zig 측이 등록. UN delegate가 알림 클릭 시 호출.
static void (*g_notification_click_callback)(const char *notification_id) = NULL;

@interface SujiNotificationDelegate : NSObject<UNUserNotificationCenterDelegate>
@end

@implementation SujiNotificationDelegate

// 앱이 foreground일 때도 알림 표시 (default는 foreground면 무음으로 묻힘).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    willPresentNotification:(UNNotification *)notification
    withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    if (@available(macOS 11.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound);
    }
}

// 사용자가 알림 클릭/액션 → Zig 콜백.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
    withCompletionHandler:(void (^)(void))completionHandler {
    NSString *identifier = response.notification.request.identifier;
    if (g_notification_click_callback && identifier) {
        const char *cstr = [identifier UTF8String];
        if (cstr) g_notification_click_callback(cstr);
    }
    completionHandler();
}

@end

static SujiNotificationDelegate *g_delegate = nil;

int suji_notification_is_supported(void) {
    NSString *bundle_id = [[NSBundle mainBundle] bundleIdentifier];
    return (bundle_id != nil && bundle_id.length > 0) ? 1 : 0;
}

// nested run loop pattern — completion handler가 done flag set할 때까지 NSApp 이벤트 dispatch.
// dialog.m의 wait_for_completion과 같은 패턴.
static void wait_for_done(volatile BOOL *done) {
    while (!*done) {
        @autoreleasepool {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate distantFuture]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event) [NSApp sendEvent:event];
        }
    }
}

// Zig가 C 함수 포인터 등록 — 이후 알림 클릭 시 이 콜백으로 dispatch.
// 첫 호출 시 delegate를 UN center에 attach.
void suji_notification_set_click_callback(void (*cb)(const char *)) {
    if (!suji_notification_is_supported()) return;
    g_notification_click_callback = cb;
    if (!g_delegate) {
        g_delegate = [[SujiNotificationDelegate alloc] init];
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = g_delegate;
    }
}

// 권한 요청 — 첫 호출 시 OS 다이얼로그. 동기 대기 (nested run loop).
// 반환: 1 = granted, 0 = denied (또는 에러).
int suji_notification_request_permission(void) {
    if (!suji_notification_is_supported()) return 0;
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    __block int granted = 0;
    __block BOOL done = NO;
    UNAuthorizationOptions opts = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
    [center requestAuthorizationWithOptions:opts
                          completionHandler:^(BOOL g, NSError * _Nullable err) {
        granted = (g && err == nil) ? 1 : 0;
        done = YES;
    }];
    wait_for_done(&done);
    return granted;
}

// 알림 표시. id는 caller-controlled 식별자 (close에 사용). silent=1이면 sound 없음.
// 반환: 1 = success, 0 = error (권한 없음 등).
int suji_notification_show(const char *id, const char *title, const char *body, int silent) {
    if (!suji_notification_is_supported()) return 0;
    if (id == NULL) return 0;
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    if (title && *title) content.title = [NSString stringWithUTF8String:title];
    if (body && *body) content.body = [NSString stringWithUTF8String:body];
    if (!silent) content.sound = [UNNotificationSound defaultSound];

    NSString *identifier = [NSString stringWithUTF8String:id];
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:identifier
                                                                      content:content
                                                                      trigger:nil];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    __block int success = 0;
    __block BOOL done = NO;
    [center addNotificationRequest:req withCompletionHandler:^(NSError * _Nullable err) {
        success = (err == nil) ? 1 : 0;
        done = YES;
    }];
    wait_for_done(&done);
    return success;
}

// 알림 제거 — pending(미발화) + delivered(이미 표시) 모두 해제.
void suji_notification_close(const char *id) {
    if (!suji_notification_is_supported()) return;
    if (id == NULL) return;
    NSString *identifier = [NSString stringWithUTF8String:id];
    NSArray<NSString *> *ids = @[identifier];
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center removeDeliveredNotificationsWithIdentifiers:ids];
    [center removePendingNotificationRequestsWithIdentifiers:ids];
}
