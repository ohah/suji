// notification_rich_macos.m
//
// UNUserNotificationCenter rich notification wrapper for
// @suji/plugin-notification-rich. Zig cannot construct ObjC blocks directly,
// so this file owns authorization/add completion handlers and action delegate
// callbacks.

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <AppKit/AppKit.h>

static void (*g_action_callback)(const char *notification_id, const char *action_id) = NULL;
static NSMutableSet<UNNotificationCategory *> *g_categories = nil;

@interface SujiRichNotificationDelegate : NSObject<UNUserNotificationCenterDelegate>
@end

@implementation SujiRichNotificationDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    UNNotificationPresentationOptions sound = notification.request.content.sound ? UNNotificationPresentationOptionSound : 0;
    if (@available(macOS 11.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner | sound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert | sound);
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSString *identifier = response.notification.request.identifier;
    NSString *action = response.actionIdentifier;
    if ([action isEqualToString:UNNotificationDismissActionIdentifier]) {
        completionHandler();
        return;
    }
    if ([action isEqualToString:UNNotificationDefaultActionIdentifier]) {
        action = @"default";
    }
    if (g_action_callback && identifier && action) {
        const char *id_c = [identifier UTF8String];
        const char *action_c = [action UTF8String];
        if (id_c && action_c) g_action_callback(id_c, action_c);
    }
    completionHandler();
}

@end

static SujiRichNotificationDelegate *g_delegate = nil;
static BOOL g_authorization_requested = NO;

static int is_supported(void) {
    NSString *bundle_id = [[NSBundle mainBundle] bundleIdentifier];
    return (bundle_id != nil && bundle_id.length > 0) ? 1 : 0;
}

static void ensure_delegate(void) {
    if (!g_delegate) {
        g_delegate = [[SujiRichNotificationDelegate alloc] init];
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = g_delegate;
    }
    if (!g_categories) {
        g_categories = [[NSMutableSet alloc] init];
    }
}

static void wait_for_done(volatile BOOL *done) {
    while (!*done) {
        @autoreleasepool {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event) [NSApp sendEvent:event];
        }
    }
}

static int ensure_authorized(void) {
    if (!is_supported()) return 0;
    ensure_delegate();
    if (g_authorization_requested) return 1;
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
    g_authorization_requested = YES;
    return granted;
}

void suji_notification_rich_macos_set_action_callback(void (*cb)(const char *, const char *)) {
    g_action_callback = cb;
    if (is_supported()) ensure_delegate();
}

int suji_notification_rich_macos_show(
    const char *id,
    const char *title,
    const char *body,
    const char *image_path,
    int silent,
    const char * const *action_ids,
    const char * const *action_labels,
    int action_count
) {
    if (!id || !title || !body) return 0;
    if (!ensure_authorized()) return 0;

    NSString *identifier = [NSString stringWithUTF8String:id];
    if (!identifier) return 0;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString stringWithUTF8String:title] ?: @"";
    content.body = [NSString stringWithUTF8String:body] ?: @"";
    if (!silent) content.sound = [UNNotificationSound defaultSound];

    if (image_path && image_path[0]) {
        NSString *path = [NSString stringWithUTF8String:image_path];
        if (path) {
            NSURL *url = [NSURL fileURLWithPath:path];
            NSError *attachment_error = nil;
            UNNotificationAttachment *attachment =
                [UNNotificationAttachment attachmentWithIdentifier:@"image"
                                                               URL:url
                                                           options:nil
                                                             error:&attachment_error];
            if (attachment && attachment_error == nil) {
                content.attachments = @[attachment];
            }
        }
    }

    if (action_count > 0 && action_ids && action_labels) {
        NSMutableArray<UNNotificationAction *> *actions = [[NSMutableArray alloc] init];
        for (int i = 0; i < action_count; i++) {
            if (!action_ids[i] || !action_labels[i]) continue;
            NSString *action_id = [NSString stringWithUTF8String:action_ids[i]];
            NSString *label = [NSString stringWithUTF8String:action_labels[i]];
            if (!action_id || !label || action_id.length == 0 || label.length == 0) continue;
            UNNotificationAction *action =
                [UNNotificationAction actionWithIdentifier:action_id
                                                     title:label
                                                   options:UNNotificationActionOptionForeground];
            [actions addObject:action];
        }
        if (actions.count > 0) {
            NSString *category_id = [NSString stringWithFormat:@"suji.rich.%@", identifier];
            UNNotificationCategory *category =
                [UNNotificationCategory categoryWithIdentifier:category_id
                                                       actions:actions
                                             intentIdentifiers:@[]
                                                       options:UNNotificationCategoryOptionCustomDismissAction];
            [g_categories addObject:category];
            [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories:g_categories];
            content.categoryIdentifier = category_id;
        }
    }

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];

    __block int success = 0;
    __block BOOL done = NO;
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:^(NSError * _Nullable err) {
        success = (err == nil) ? 1 : 0;
        done = YES;
    }];
    wait_for_done(&done);
    return success;
}

void suji_notification_rich_macos_hide(const char *id) {
    if (!id || !is_supported()) return;
    NSString *identifier = [NSString stringWithUTF8String:id];
    if (!identifier) return;
    NSArray<NSString *> *ids = @[identifier];
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center removeDeliveredNotificationsWithIdentifiers:ids];
    [center removePendingNotificationRequestsWithIdentifiers:ids];
}
