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

    const repr_fn: *const fn (?*anyopaque, ?*anyopaque, c_long, ?*anyopaque) callconv(.c) ?*anyopaque =
        @ptrCast(&objc.objc_msgSend);
    const out_data = repr_fn(
        rep,
        @ptrCast(objc.sel_registerName("representationUsingType:properties:")),
        @intFromEnum(file_type),
        props,
    ) orelse return out_buf[0..0];

    const len_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const len = len_fn(out_data, @ptrCast(objc.sel_registerName("length")));
    if (len > out_buf.len) return out_buf[0..0];
    const bytes_fn: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) [*c]const u8 = @ptrCast(&objc.objc_msgSend);
    const bytes = bytes_fn(out_data, @ptrCast(objc.sel_registerName("bytes")));
    if (bytes == null) return out_buf[0..0];
    @memcpy(out_buf[0..len], bytes[0..len]);
    return out_buf[0..len];
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
