//! nativeImage API — cef.zig 에서 분리(동작 무변경).
//! macOS NSImage/NSBitmapImageRep 기반 decode/encode bridge.
const builtin = @import("builtin");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;

const objc = cef.objc;
const getClass = cef.getClass;
const msgSend = cef.msgSend;
const nsStringFromCstr = cef.nsStringFromCstr;
const nsStringFromSlice = cef.nsStringFromSlice;

/// NSBitmapImageFileType. AppKit 헤더 값과 일치 — `representationUsingType:` 첫 인자.
pub const NSBitmapImageFileType = enum(c_long) {
    tiff = 0,
    bmp = 1,
    gif = 2,
    jpeg = 3,
    png = 4,
    jpeg2000 = 5,
};

/// NSBitmapImageRep → 인코딩된 bytes(`representationUsingType:properties:`). out_buf
/// 부족 시 빈 slice. nativeImageEncodeFromPath/nativeImageFileIconPng 공용 tail.
/// rep 수명은 호출자 소유(EncodeFromPath=imageRepWithData autoreleased, fileIcon=
/// alloc+defer release) — 헬퍼는 rep 을 retain/release 하지 않는다.
fn encodeRepToBuf(rep: ?*anyopaque, file_type: NSBitmapImageFileType, props: ?*anyopaque, out_buf: []u8) []const u8 {
    const repr_fn: *const fn (?*anyopaque, ?*anyopaque, c_long, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const out_data = repr_fn(rep, @ptrCast(objc.sel_registerName("representationUsingType:properties:")), @intFromEnum(file_type), props) orelse
        return out_buf[0..0];
    const len_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const len = len_fn(out_data, @ptrCast(objc.sel_registerName("length")));
    if (len > out_buf.len) return out_buf[0..0];
    const bytes_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) [*c]const u8 = @ptrCast(&objc.objc_msgSend);
    const bytes = bytes_fn(out_data, @ptrCast(objc.sel_registerName("bytes")));
    if (bytes == null) return out_buf[0..0];
    @memcpy(out_buf[0..len], bytes[0..len]);
    return out_buf[0..len];
}

/// 이미지 파일 → 인코딩된 bytes (Electron `nativeImage.createFromPath(path).toPNG()` /
/// `.toJPEG(quality)`). 파일 bytes → NSBitmapImageRep `imageRepWithData:` 한 번 디코드 후
/// `representationUsingType:properties:`로 재인코딩. NSImage 우회 시 TIFF 중간 단계 발생해서 회피.
/// jpeg_quality는 0~100 (PNG 호출 시 무시). out_buf 부족 시 빈 slice (truncation 방지).
pub fn nativeImageEncodeFromPath(
    path: []const u8,
    file_type: NSBitmapImageFileType,
    jpeg_quality: f64,
    out_buf: []u8,
) []const u8 {
    if (!comptime is_macos) return out_buf[0..0];
    const ns_path = nsStringFromSlice(path) orelse return out_buf[0..0];
    const NSData = getClass("NSData") orelse return out_buf[0..0];
    const data_fn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const file_data = data_fn(NSData, @ptrCast(objc.sel_registerName("dataWithContentsOfFile:")), ns_path) orelse
        return out_buf[0..0];

    const NSBitmapImageRep = getClass("NSBitmapImageRep") orelse return out_buf[0..0];
    const rep = data_fn(NSBitmapImageRep, @ptrCast(objc.sel_registerName("imageRepWithData:")), file_data) orelse
        return out_buf[0..0];

    var props: ?*anyopaque = null;
    if (file_type == .jpeg) {
        const NSNumber = getClass("NSNumber") orelse return out_buf[0..0];
        const num_fn: *const fn (?*anyopaque, ?*anyopaque, f64) callconv(.c) ?*anyopaque =
            @ptrCast(&objc.objc_msgSend);
        const factor = num_fn(NSNumber, @ptrCast(objc.sel_registerName("numberWithDouble:")), jpeg_quality / 100.0) orelse
            return out_buf[0..0];
        const NSDict = getClass("NSDictionary") orelse return out_buf[0..0];
        const factor_key = nsStringFromCstr("NSImageCompressionFactor") orelse return out_buf[0..0];
        const dict_fn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque =
            @ptrCast(&objc.objc_msgSend);
        props = dict_fn(NSDict, @ptrCast(objc.sel_registerName("dictionaryWithObject:forKey:")), factor, factor_key);
    }

    return encodeRepToBuf(rep, file_type, props, out_buf);
}

/// 파일의 시스템 아이콘 → PNG bytes (Electron `app.getFileIcon(path)`).
/// NSWorkspace.iconForFile: → NSImage → CGImageForProposedRect 32x32 →
/// NSBitmapImageRep → PNG. macOS only(NSWorkspace). Win/Linux: 빈 slice(honest).
/// out_buf 부족 시 빈 slice.
pub fn nativeImageFileIconPng(path: []const u8, out_buf: []u8) []const u8 {
    if (!comptime is_macos) return out_buf[0..0];
    const ns_path = nsStringFromSlice(path) orelse return out_buf[0..0];
    const NSWorkspace = getClass("NSWorkspace") orelse return out_buf[0..0];
    const obj0_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const ws = obj0_fn(NSWorkspace, @ptrCast(objc.sel_registerName("sharedWorkspace"))) orelse return out_buf[0..0];
    const icon_fn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const img = icon_fn(ws, @ptrCast(objc.sel_registerName("iconForFile:")), ns_path) orelse return out_buf[0..0];
    // multi-rep TIFF 의 PNG 는 12KB(b64) 한도를 넘으므로 32x32 단일 비트맵으로 축소
    // (CGImageForProposedRect: → NSBitmapImageRep initWithCGImage:). 런처/파일매니저용 작은 아이콘.
    var rect = cef.NSRect{ .x = 0, .y = 0, .width = 32, .height = 32 };
    const cg_fn: *const fn (?*anyopaque, ?*anyopaque, *cef.NSRect, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const cg = cg_fn(img, @ptrCast(objc.sel_registerName("CGImageForProposedRect:context:hints:")), &rect, null, null) orelse return out_buf[0..0];
    const NSBitmapImageRep = getClass("NSBitmapImageRep") orelse return out_buf[0..0];
    const rep_raw = obj0_fn(NSBitmapImageRep, @ptrCast(objc.sel_registerName("alloc"))) orelse return out_buf[0..0];
    const init_fn: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc.objc_msgSend);
    const rep = init_fn(rep_raw, @ptrCast(objc.sel_registerName("initWithCGImage:")), cg) orelse return out_buf[0..0];
    // rep 은 alloc+init(retain +1). nativeImageEncodeFromPath 의 imageRepWithData(autoreleased)
    // 와 일관되게 autorelease 로 등록(cefHandleCore=UI 스레드 autorelease pool 보유) — defer
    // release 는 init 실패(rep null, 위 orelse return) 시 alloc 된 rep_raw 의 정리 경로가
    // 갈려 모호했으나, init 성공 후 단일 autorelease 로 누수/이중해제 없이 일관 정리.
    _ = obj0_fn(rep, @ptrCast(objc.sel_registerName("autorelease")));
    return encodeRepToBuf(rep, .png, null, out_buf);
}

/// 이미지 파일 → dimensions (Electron `nativeImage.createFromPath(path).getSize()`).
/// macOS NSImage initWithContentsOfFile: + size (point 단위). pixel은 representation
/// 사용 (1차 후속). file 없거나 디코딩 실패 시 width/height = 0.
pub fn nativeImageGetSize(path: []const u8) cef.NSSize {
    if (!comptime is_macos) return .{ .width = 0, .height = 0 };
    const img = cef.loadNSImageFromFile(path) orelse return .{ .width = 0, .height = 0 };
    const size_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) cef.NSSize =
        @ptrCast(&objc.objc_msgSend);
    return size_fn(img, @ptrCast(objc.sel_registerName("size")));
}

/// Electron `nativeImage.createFromPath(path).isEmpty()` — 로드 실패/크기 0 이면 true.
/// nativeImageGetSize 재사용(비-macOS/실패 시 {0,0} → empty).
pub fn nativeImageIsEmpty(path: []const u8) bool {
    const sz = nativeImageGetSize(path);
    return sz.width <= 0 or sz.height <= 0;
}

/// Electron `nativeImage.isTemplateImage()` — NSImage.isTemplate(메뉴바 자동 틴트 대상 여부).
/// macOS only(NSImage 메타데이터). Win/Linux: false(미지원 honest).
pub fn nativeImageIsTemplate(path: []const u8) bool {
    if (!comptime is_macos) return false;
    const img = cef.loadNSImageFromFile(path) orelse return false;
    return cef.msgSendBool(img, "isTemplate");
}
