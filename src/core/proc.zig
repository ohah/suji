//! 공용 프로세스 실행 헬퍼. bundle_macos/package_desktop/main 이 각자
//! 복제하던 spawn→wait→exit-code 패턴의 단일 출처.
const std = @import("std");
const runtime = @import("runtime");

/// argv 실행, 종료코드 0 이 아니면 error.CommandFailed.
pub fn run(argv: []const []const u8) !void {
    var child = try std.process.spawn(runtime.io, .{ .argv = argv });
    switch (try child.wait(runtime.io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}
