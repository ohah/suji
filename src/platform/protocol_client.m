// Electron app.setAsDefaultProtocolClient / isDefaultProtocolClient /
// removeAsDefaultProtocolClient — macOS Launch Services.
//
// 정직 경계: 런타임 기본-핸들러 지정/조회는 **실 .app 번들에서만** 동작한다(번들
// identifier 필요). dev(맨 실행 파일)은 CFBundleIdentifier 부재 → 모두 graceful 0.
// URL scheme "등록"(앱이 myapp:// 를 처리) 자체는 이미 선언적 경로
// (suji.json `app.deepLinkSchemes` → Info.plist `CFBundleURLTypes`, bundle_macos.zig)
// 가 담당한다 — 이 트리오는 그 위에서 "기본 핸들러로 강제/조회"하는 Electron 보조 API.

#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>

static NSString *sujiMainBundleID(void) {
  NSBundle *b = [NSBundle mainBundle];
  if (!b) return nil;
  return [b bundleIdentifier]; // 비-.app(dev) → nil
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// LSSetDefaultHandlerForURLScheme / LSCopyDefaultHandlerForURLScheme 는 macOS 12 에서
// deprecated 됐지만 C ABI 대체가 없다(대체는 NSWorkspace async ObjC). Electron 도
// 동일 LS 경로 사용 — deprecation 경고만 억제.

// 우리 앱을 scheme 의 기본 핸들러로 지정. 성공 1, 실패/번들없음 0.
int suji_protocol_set_default(const char *scheme) {
  if (!scheme) return 0;
  NSString *bid = sujiMainBundleID();
  if (!bid) return 0;
  NSString *s = [NSString stringWithUTF8String:scheme];
  if (!s) return 0;
  OSStatus st = LSSetDefaultHandlerForURLScheme((__bridge CFStringRef)s,
                                                (__bridge CFStringRef)bid);
  return st == noErr ? 1 : 0;
}

// 우리 앱이 scheme 의 현재 기본 핸들러인지. 맞으면 1, 아니면/번들없음 0.
int suji_protocol_is_default(const char *scheme) {
  if (!scheme) return 0;
  NSString *bid = sujiMainBundleID();
  if (!bid) return 0;
  NSString *s = [NSString stringWithUTF8String:scheme];
  if (!s) return 0;
  CFStringRef cur = LSCopyDefaultHandlerForURLScheme((__bridge CFStringRef)s);
  if (!cur) return 0;
  BOOL match =
      [bid caseInsensitiveCompare:(__bridge NSString *)cur] == NSOrderedSame;
  CFRelease(cur);
  return match ? 1 : 0;
}
#pragma clang diagnostic pop

// macOS Launch Services 엔 "기본 핸들러 해제" API 가 없다(다른 앱으로 재지정만 가능).
// Electron 도 macOS 에서 removeAsDefaultProtocolClient 미지원(false) → 동형 0.
int suji_protocol_remove_default(const char *scheme) {
  (void)scheme;
  return 0;
}
