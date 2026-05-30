//! Shared Dialog JSON response writers.

const std = @import("std");
const util = @import("util");

pub fn writeCanceledResponse(buf: []u8, canceled: bool) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"canceled\":{},\"filePaths\":[]}}",
        .{canceled},
    ) catch buf[0..0];
}

pub fn writeSaveCanceledResponse(buf: []u8, canceled: bool) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"canceled\":{},\"filePath\":\"\"}}",
        .{canceled},
    ) catch buf[0..0];
}

pub fn writeSaveSuccessResponse(buf: []u8, path: []const u8) []const u8 {
    var esc_buf: [util.MAX_RESPONSE]u8 = undefined;
    const esc_len = util.escapeJsonStrFull(path, &esc_buf) orelse return writeSaveCanceledResponse(buf, true);
    return std.fmt.bufPrint(
        buf,
        "{{\"canceled\":false,\"filePath\":\"{s}\"}}",
        .{esc_buf[0..esc_len]},
    ) catch writeSaveCanceledResponse(buf, true);
}
