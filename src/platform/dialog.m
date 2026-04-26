// src/platform/dialog.m
//
// Sheet-style modal helpers. NSAlert/NSOpenPanel/NSSavePanel의 sheet API는
// completion handler로 ObjC block(^)을 받는데, Zig에선 native block 생성 불가 →
// 이 파일이 ObjC 컴파일러에서 `^{ ... }` 문법을 사용해 bridge 역할.
//
// 흐름:
//   1. Zig가 NSAlert/NSOpenPanel을 msgSend로 알아서 구성 + 옵션 적용
//   2. void* 포인터로 이 파일의 함수에 넘김 (parent NSWindow + 패널 객체)
//   3. 이 파일이 beginSheetModalForWindow:completionHandler:^(NSModalResponse)
//      호출 + nested NSApp run loop로 동기 대기 → response 코드 반환
//
// nested run loop 패턴: CEF UI 스레드(=NSApp main)가 IPC 핸들러 처리 중 sheet
// 시작 → 콜백이 done 플래그 set + stopModal 흉내 → 핸들러 정상 반환. CEF 자체
// 메시지 루프(cef_run_message_loop)는 외부에 그대로 있고, 우리는 그 안에서 한
// 번 더 nested 이벤트 dispatch. CEF 이벤트도 NSApp 통해 흐르므로 정상 처리.
//
// ARC 사용 (-fobjc-arc) — __bridge 캐스트 명시.

#import <Cocoa/Cocoa.h>

// done 플래그가 set될 때까지 NSApp 이벤트 dispatch 반복.
// nextEventMatchingMask:dequeue:YES + sendEvent로 직접 디스패치 — 표준 nested
// loop 패턴 (Apple 공식 문서 권장).
static void suji_wait_for_completion(volatile BOOL *done) {
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

// NSAlert sheet — 부모 창에 부착, 사용자 클릭까지 동기 대기.
// 반환: NSAlertFirstButtonReturn(1000) + 클릭한 버튼 index. 부모 nil/유효 X면 -1.
NSInteger suji_run_sheet_alert(void *parent_window_ptr, void *alert_ptr) {
    if (parent_window_ptr == NULL || alert_ptr == NULL) return -1;
    NSWindow *parent = (__bridge NSWindow *)parent_window_ptr;
    NSAlert *alert = (__bridge NSAlert *)alert_ptr;

    __block NSInteger response = -1;
    __block BOOL done = NO;

    [alert beginSheetModalForWindow:parent
                  completionHandler:^(NSModalResponse code) {
        response = code;
        done = YES;
    }];

    suji_wait_for_completion(&done);
    return response;
}

// NSOpenPanel/NSSavePanel sheet (둘 다 NSSavePanel 상속).
// 반환: NSModalResponseOK(1) / NSModalResponseCancel(0). 부모 nil이면 -1.
NSInteger suji_run_sheet_save_panel(void *parent_window_ptr, void *panel_ptr) {
    if (parent_window_ptr == NULL || panel_ptr == NULL) return -1;
    NSWindow *parent = (__bridge NSWindow *)parent_window_ptr;
    NSSavePanel *panel = (__bridge NSSavePanel *)panel_ptr;

    __block NSInteger response = -1;
    __block BOOL done = NO;

    [panel beginSheetModalForWindow:parent
                  completionHandler:^(NSModalResponse code) {
        response = code;
        done = YES;
    }];

    suji_wait_for_completion(&done);
    return response;
}
