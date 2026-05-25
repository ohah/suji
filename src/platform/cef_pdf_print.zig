const std = @import("std");

pub const PaperSize = struct {
    width: i32,
    height: i32,
};

/// CEF Linux `print_to_pdf` needs a non-zero paper size from
/// `cef_print_handler_t.get_pdf_paper_size`. Use cefclient's default U.S. Letter
/// page in device units.
pub fn defaultPaperSize(device_units_per_inch: i32) PaperSize {
    const dpi: f64 = @floatFromInt(device_units_per_inch);
    return .{
        .width = @intFromFloat(8.5 * dpi),
        .height = @intFromFloat(11.0 * dpi),
    };
}

test "defaultPaperSize returns U.S. Letter dimensions in device units" {
    const size_72 = defaultPaperSize(72);
    try std.testing.expectEqual(@as(i32, 612), size_72.width);
    try std.testing.expectEqual(@as(i32, 792), size_72.height);

    const size_96 = defaultPaperSize(96);
    try std.testing.expectEqual(@as(i32, 816), size_96.width);
    try std.testing.expectEqual(@as(i32, 1056), size_96.height);
}

test "defaultPaperSize truncates fractional device units like CEF size fields" {
    const size = defaultPaperSize(101);
    try std.testing.expectEqual(@as(i32, 858), size.width);
    try std.testing.expectEqual(@as(i32, 1111), size.height);
}
