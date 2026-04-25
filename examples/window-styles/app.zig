const std = @import("std");
const suji = @import("suji");

pub const app = suji.app()
    .handle("ping", ping)
    .handle("whoami", whoami)
    // 메인 창에서 호출 → 모든 창에 broadcast (HUD가 구독해서 toast 표시).
    .handle("hud-toast", hudToast)
    .on("window:all-closed", onWindowAllClosed);

fn ping(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    return req.ok(.{
        .pong = true,
        .from_window_id = event.window.id,
        .from_window_name = event.window.name orelse "",
    });
}

fn whoami(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    return req.ok(.{
        .id = event.window.id,
        .name = event.window.name orelse "",
        .url = event.window.url orelse "",
        .is_main_frame = event.window.is_main_frame orelse false,
    });
}

fn hudToast(req: suji.Request, event: suji.InvokeEvent) suji.Response {
    _ = event;
    const text = req.string("text") orelse "hello HUD";
    var buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"text\":\"{s}\"}}", .{text}) catch return req.err("alloc");
    // broadcast — 모든 창이 받지만 hud만 on('hud:toast') 리스너 등록.
    suji.send("hud:toast", payload);
    return req.ok(.{ .ok = true });
}

fn onWindowAllClosed(_: suji.Event) void {
    if (!std.mem.eql(u8, suji.platform(), suji.PLATFORM_MACOS)) suji.quit();
}
