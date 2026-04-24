const std = @import("std");
const suji = @import("suji");

pub const app = suji.app()
    .handle("ping", ping)
    .handle("greet", greet)
    .handle("add", add)
    // Electron 스타일: `app.on('window-all-closed', ...)` 대응.
    // macOS는 창 닫혀도 앱 유지(dock), 그 외는 종료 — 전형적인 Electron 패턴.
    .on("window:all-closed", onWindowAllClosed);

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong" });
}

fn greet(req: suji.Request) suji.Response {
    const name = req.string("name") orelse "world";
    return req.ok(.{ .msg = name, .greeting = "Hello from Zig!" });
}

fn add(req: suji.Request) suji.Response {
    const a = req.int("a") orelse 0;
    const b = req.int("b") orelse 0;
    return req.ok(.{ .result = a + b });
}

fn onWindowAllClosed(_: suji.Event) void {
    const platform = suji.platform();
    std.debug.print("[Zig] window-all-closed received (platform={s})\n", .{platform});
    // macOS는 Electron 관례상 앱 유지(dock). 나머지는 종료.
    if (!std.mem.eql(u8, platform, suji.PLATFORM_MACOS)) {
        std.debug.print("[Zig] non-macOS → suji.quit()\n", .{});
        suji.quit();
    }
}

comptime {
    _ = suji.exportApp(app);
}
