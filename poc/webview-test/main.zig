const std = @import("std");
const wv = @import("webview");

fn myCallback(seq: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    std.debug.print("CALLBACK CALLED! seq={s} req={s}\n", .{ std.mem.span(seq), std.mem.span(req) });
    // 항상 성공 반환
}

pub fn main() !void {
    std.debug.print("Creating webview...\n", .{});
    const w = wv.WebView.create(true, null);

    std.debug.print("Setting title...\n", .{});
    w.setTitle("Bind Test") catch {};

    std.debug.print("Setting size...\n", .{});
    w.setSize(400, 300, .none) catch {};

    std.debug.print("Binding function...\n", .{});
    _ = wv.raw.webview_bind(w.webview, "myFunc", @ptrCast(&myCallback), null);

    std.debug.print("Setting HTML...\n", .{});
    w.setHtml(
        \\<button onclick="myFunc('hello').then(r=>document.body.innerHTML+='<br>Result: '+r).catch(e=>document.body.innerHTML+='<br>Error: '+JSON.stringify(e))">Test Bind</button>
    ) catch {};

    std.debug.print("Running...\n", .{});
    w.run() catch {};
    w.destroy() catch {};
}
