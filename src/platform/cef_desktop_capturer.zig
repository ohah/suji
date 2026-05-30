//! desktopCapturer — cef.zig 에서 분리(동작 무변경). macOS CoreGraphics
//! source enumeration + ImageIO thumbnail encoding.
const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const desktop_capturer = @import("desktop_capturer.zig");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;

const NSRect = cef.NSRect;
const CFRelease = cef.CFRelease;

// ============================================
// desktopCapturer — 화면/창 소스 목록 (Electron `desktopCapturer.getSources`)
// ============================================
// CEF 직접 미제공 → macOS CoreGraphics. 스크린=CGGetActiveDisplayList,
// 창=CGWindowListCopyWindowInfo(레이어 0 = 일반 앱 창만; ExcludeDesktop
// Elements 로 배경/Dock 아이콘 제외). CG 심볼은 Cocoa/Carbon 링크에
// transitive(기존 CGEventSource* extern 과 동일하게 별도 linkFramework 불요).
//
// ⚠️ 정직 경계: thumbnail/appIcon 미포함. Electron 은 소스마다 NativeImage
// 썸네일을 주지만 (1) 화면 캡처는 Screen Recording TCC 권한 필요(헤드리스
// 부여/검증 불가) (2) base64 PNG 는 IPC payload 한도 초과(capture_page 가
// 파일경로 방식인 이유와 동일). 소스 열거(id/name/type/bounds/display_id)만
// 제공 — 썸네일은 ScreenCaptureKit + 권한 기반 후속(문서 명시).

extern "c" fn CGGetActiveDisplayList(max: u32, displays: ?[*]u32, count: *u32) c_int;
extern "c" fn CGMainDisplayID() u32;
extern "c" fn CGDisplayBounds(display: u32) NSRect;
extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) ?*anyopaque;
extern "c" fn CFArrayGetCount(arr: ?*anyopaque) c_long;
extern "c" fn CFArrayGetValueAtIndex(arr: ?*anyopaque, idx: c_long) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(dict: ?*anyopaque, key: ?*anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(num: ?*anyopaque, the_type: c_long, value_ptr: *anyopaque) u8;
extern "c" fn CFStringGetCString(str: ?*anyopaque, buf: [*]u8, size: c_long, encoding: u32) u8;
extern "c" fn CGRectMakeWithDictionaryRepresentation(dict: ?*anyopaque, rect: *NSRect) u8;
extern "c" const kCGWindowNumber: ?*anyopaque;
extern "c" const kCGWindowOwnerName: ?*anyopaque;
extern "c" const kCGWindowName: ?*anyopaque;
extern "c" const kCGWindowBounds: ?*anyopaque;
extern "c" const kCGWindowLayer: ?*anyopaque;

const kCFNumberSInt64Type: c_long = 4;
const kCFStringEncodingUTF8: u32 = 0x08000100;
// kCGWindowListOptionOnScreenOnly(1) | kCGWindowListExcludeDesktopElements(16).
const kCGWindowListSourcesOption: u32 = 1 | 16;

/// CFString → UTF-8, 그 다음 JSON escape 까지 한 번에. 실패/빈값이면 false.
fn cfStringToJson(w: *std.Io.Writer, cf: ?*anyopaque) bool {
    const s = cf orelse return false;
    var raw: [512]u8 = undefined;
    if (CFStringGetCString(s, &raw, raw.len, kCFStringEncodingUTF8) == 0) return false;
    const len = std.mem.indexOfScalar(u8, &raw, 0) orelse raw.len;
    if (len == 0) return false;
    var esc: [1024]u8 = undefined;
    const en = window_mod.escapeJsonChars(raw[0..len], &esc);
    // 전부 제어문자(escapeJsonChars 가 드롭)면 빈 결과 → 실패로 간주해
    // caller 의 owner/"Window" 폴백 체인이 동작하도록(빈 name 회피).
    if (en == 0) return false;
    w.writeAll(esc[0..en]) catch return false;
    return true;
}

/// 화면/창 소스 목록 JSON 배열. want_screen/want_window 로 type 필터.
pub fn desktopCapturerGetSources(out_buf: []u8, want_screen: bool, want_window: bool) []const u8 {
    if (!comptime is_macos) {
        const empty = "[]";
        const n = @min(empty.len, out_buf.len);
        @memcpy(out_buf[0..n], empty[0..n]);
        return out_buf[0..n];
    }
    var w = std.Io.Writer.fixed(out_buf);
    w.writeByte('[') catch return out_buf[0..1];
    var first = true;

    if (want_screen) {
        var ids: [16]u32 = undefined;
        var n: u32 = 0;
        if (CGGetActiveDisplayList(ids.len, &ids, &n) == 0) {
            const main_id = CGMainDisplayID();
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const did = ids[k];
                const b = CGDisplayBounds(did);
                if (!first) w.writeByte(',') catch return w.buffered();
                first = false;
                w.print(
                    "{{\"id\":\"screen:{d}:0\",\"name\":\"{s}\",\"type\":\"screen\",\"displayId\":{d},\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
                    .{
                        did,
                        if (did == main_id) "Entire screen" else "Screen",
                        did,
                        @as(i64, @intFromFloat(b.x)),
                        @as(i64, @intFromFloat(b.y)),
                        @as(i64, @intFromFloat(b.width)),
                        @as(i64, @intFromFloat(b.height)),
                    },
                ) catch return w.buffered();
            }
        }
    }

    if (want_window) {
        const arr = CGWindowListCopyWindowInfo(kCGWindowListSourcesOption, 0);
        if (arr) |a| {
            defer CFRelease(a);
            const total = CFArrayGetCount(a);
            var idx: c_long = 0;
            while (idx < total) : (idx += 1) {
                const dict = CFArrayGetValueAtIndex(a, idx) orelse continue;

                // 레이어 0(일반 앱 창)만 — 메뉴바/Dock/배경 제외.
                var layer: i64 = -1;
                if (CFDictionaryGetValue(dict, kCGWindowLayer)) |lv|
                    _ = CFNumberGetValue(lv, kCFNumberSInt64Type, @ptrCast(&layer));
                if (layer != 0) continue;

                var winnum: i64 = 0;
                if (CFDictionaryGetValue(dict, kCGWindowNumber)) |nv|
                    _ = CFNumberGetValue(nv, kCFNumberSInt64Type, @ptrCast(&winnum));
                if (winnum == 0) continue;

                var bounds: NSRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                if (CFDictionaryGetValue(dict, kCGWindowBounds)) |bv|
                    _ = CGRectMakeWithDictionaryRepresentation(bv, &bounds);
                // 너무 작은(1px 미만) 창 = 보조/숨김 — 제외.
                if (bounds.width < 1 or bounds.height < 1) continue;

                if (!first) w.writeByte(',') catch return w.buffered();
                first = false;
                w.print("{{\"id\":\"window:{d}:0\",\"name\":\"", .{winnum}) catch return w.buffered();
                // name = 창 제목, 없으면 소유 프로세스명, 둘 다 없으면 "Window".
                const has_title = cfStringToJson(&w, CFDictionaryGetValue(dict, kCGWindowName));
                if (!has_title) {
                    if (!cfStringToJson(&w, CFDictionaryGetValue(dict, kCGWindowOwnerName)))
                        w.writeAll("Window") catch return w.buffered();
                }
                w.print(
                    "\",\"type\":\"window\",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
                    .{
                        @as(i64, @intFromFloat(bounds.x)),
                        @as(i64, @intFromFloat(bounds.y)),
                        @as(i64, @intFromFloat(bounds.width)),
                        @as(i64, @intFromFloat(bounds.height)),
                    },
                ) catch return w.buffered();
            }
        }
    }

    w.writeByte(']') catch return w.buffered();
    return w.buffered();
}

// ============================================
// desktopCapturer thumbnail — 소스 PNG 캡처 → 파일경로 (Electron NativeImage 대응)
// ============================================
// getSources 가 썸네일을 못 주는 이유(base64 IPC 한도)를 capture_page 와 동일한
// "파일경로 전달" 로 우회. 동기 CoreGraphics 캡처(CGDisplayCreateImage /
// CGWindowListCreateImage) → ImageIO(CGImageDestination) 로 PNG 인코딩.
//
// ⚠️ 정직 경계(미검증): 실제 캡처는 Screen Recording TCC 권한 필요 — 미부여
// 환경(헤드리스/CI)에선 CG*CreateImage 가 null 반환 → graceful false (crash 없음).
// 그래서 PNG 인코딩(ImageIO) 경로는 권한 있는 실기기에서만 실행 — 이 환경에선
// 컴파일/링크 + graceful-fail 만 검증, 인코딩 경로 미실행(commit/PLAN 명시).
extern "c" fn CGDisplayCreateImage(display: u32) ?*anyopaque;
extern "c" fn CGWindowListCreateImage(bounds: NSRect, list_option: u32, window_id: u32, image_option: u32) ?*anyopaque;
extern "c" fn CGImageRelease(image: ?*anyopaque) void;
extern "c" const CGRectNull: NSRect;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) ?*anyopaque;
extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, path: [*]const u8, len: c_long, is_dir: u8) ?*anyopaque;
extern "c" fn CGImageDestinationCreateWithURL(url: ?*anyopaque, ty: ?*anyopaque, count: usize, options: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageDestinationAddImage(dest: ?*anyopaque, image: ?*anyopaque, props: ?*anyopaque) void;
extern "c" fn CGImageDestinationFinalize(dest: ?*anyopaque) u8;

const kCGWindowListOptionIncludingWindow: u32 = 8;
const kCGWindowImageDefault: u32 = 0;

/// desktopCapturer source(screen/window)를 PNG 로 캡처해 `path` 에 기록. 동기.
/// TCC 미부여/무효 id/인코딩 실패 시 false (graceful — crash 없음).
pub fn desktopCapturerCaptureThumbnail(source_id: []const u8, path: []const u8) bool {
    if (!comptime is_macos) return false;
    const src = desktop_capturer.parseSourceId(source_id) orelse return false;

    const img = if (src.screen)
        CGDisplayCreateImage(src.id)
    else
        CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, src.id, kCGWindowImageDefault);
    // TCC(Screen Recording) 미부여 또는 무효 id → null. graceful false.
    const image = img orelse return false;
    defer CGImageRelease(image);

    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return false;
    defer CFRelease(url);
    const png_type = CFStringCreateWithCString(null, "public.png", kCFStringEncodingUTF8) orelse return false;
    defer CFRelease(png_type);
    const dest = CGImageDestinationCreateWithURL(url, png_type, 1, null) orelse return false;
    defer CFRelease(dest);

    CGImageDestinationAddImage(dest, image, null);
    return CGImageDestinationFinalize(dest) != 0;
}
