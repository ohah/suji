//! Zig 0.16: main이 `std.process.Init`으로 주입받은 런타임 리소스를
//! 다른 모듈에서 참조할 수 있도록 저장하는 전역 컨텍스트.
//! main 진입 초기에 `init(...)`으로 채워야 한다.

const std = @import("std");

pub var io: std.Io = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var environ_map: ?*std.process.Environ.Map = null;
pub var args_vector: std.process.Args.Vector = undefined;

pub fn init(v: struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    args_vector: std.process.Args.Vector,
}) void {
    io = v.io;
    gpa = v.gpa;
    environ_map = v.environ_map;
    args_vector = v.args_vector;
}

/// 환경변수 조회 (POSIX/Windows 모두 environ_map 경유).
pub fn env(key: []const u8) ?[]const u8 {
    const m = environ_map orelse return null;
    return m.get(key);
}
