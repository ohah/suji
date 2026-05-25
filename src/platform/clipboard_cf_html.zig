const std = @import("std");

const start_marker = "<!--StartFragment-->";
const end_marker = "<!--EndFragment-->";
const html_prefix = "<html><body>" ++ start_marker;
const html_suffix = end_marker ++ "</body></html>";

const start_html_label = "StartHTML:";
const end_html_label = "EndHTML:";
const start_fragment_label = "StartFragment:";
const end_fragment_label = "EndFragment:";

pub const format_name = "HTML Format";
pub const max_overhead = headerLen() + html_prefix.len + html_suffix.len + 1;

fn headerLen() usize {
    return "Version:0.9\r\n".len +
        start_html_label.len + 10 + "\r\n".len +
        end_html_label.len + 10 + "\r\n".len +
        start_fragment_label.len + 10 + "\r\n".len +
        end_fragment_label.len + 10 + "\r\n".len;
}

fn append(out: []u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > out.len) return false;
    @memcpy(out[pos.* .. pos.* + text.len], text);
    pos.* += text.len;
    return true;
}

fn appendDecimal10(out: []u8, pos: *usize, value: usize) bool {
    if (value > 9_999_999_999) return false;
    if (pos.* + 10 > out.len) return false;
    var n = value;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        out[pos.* + i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    pos.* += 10;
    return true;
}

/// Build a Win32 CF_HTML document whose fragment is exactly `html`.
/// Offsets are byte offsets from the beginning of the returned buffer.
pub fn writeDocument(out: []u8, html: []const u8) ?[]const u8 {
    if (html.len == 0) return null;
    const start_html = headerLen();
    const start_fragment = start_html + html_prefix.len;
    const end_fragment = start_fragment + html.len;
    const end_html = end_fragment + html_suffix.len;
    if (end_html > out.len) return null;

    var pos: usize = 0;
    if (!append(out, &pos, "Version:0.9\r\n")) return null;
    if (!append(out, &pos, start_html_label)) return null;
    if (!appendDecimal10(out, &pos, start_html)) return null;
    if (!append(out, &pos, "\r\n")) return null;
    if (!append(out, &pos, end_html_label)) return null;
    if (!appendDecimal10(out, &pos, end_html)) return null;
    if (!append(out, &pos, "\r\n")) return null;
    if (!append(out, &pos, start_fragment_label)) return null;
    if (!appendDecimal10(out, &pos, start_fragment)) return null;
    if (!append(out, &pos, "\r\n")) return null;
    if (!append(out, &pos, end_fragment_label)) return null;
    if (!appendDecimal10(out, &pos, end_fragment)) return null;
    if (!append(out, &pos, "\r\n")) return null;
    std.debug.assert(pos == start_html);

    if (!append(out, &pos, html_prefix)) return null;
    if (!append(out, &pos, html)) return null;
    if (!append(out, &pos, html_suffix)) return null;
    std.debug.assert(pos == end_html);
    return out[0..pos];
}

fn parseOffset(data: []const u8, label: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, data, label) orelse return null;
    var i = idx + label.len;
    if (i >= data.len or !std.ascii.isDigit(data[i])) return null;
    var value: usize = 0;
    while (i < data.len and std.ascii.isDigit(data[i])) : (i += 1) {
        value = std.math.mul(usize, value, 10) catch return null;
        value = std.math.add(usize, value, data[i] - '0') catch return null;
    }
    return value;
}

/// Extract the declared CF_HTML fragment. Returns null for malformed headers.
pub fn readFragment(data: []const u8) ?[]const u8 {
    const start = parseOffset(data, start_fragment_label) orelse return null;
    const end = parseOffset(data, end_fragment_label) orelse return null;
    if (start > end or end > data.len) return null;
    return data[start..end];
}
