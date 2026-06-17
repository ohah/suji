//! Zig 0.16: main이 `std.process.Init`으로 주입받은 런타임 리소스를
//! 다른 모듈에서 참조할 수 있도록 저장하는 전역 컨텍스트.
//! main 진입 초기에 `init(...)`으로 채워야 한다.

const std = @import("std");
const builtin = @import("builtin");

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

/// 환경변수 설정 — OS 환경(서브프로세스 상속용)과 현재 프로세스 environ_map 둘 다.
/// CEF 렌더러 등 자식 프로세스는 OS env 를 상속해 시작 시 파싱하므로, 부모가 여기서
/// OS env 를 set 하면 자식 프로세스의 runtime.env() 에서도 보인다(POSIX). Windows 는
/// 현재 프로세스 갱신만(자식 상속은 추후 _putenv).
// libc setenv — Zig 0.16 std.c 에 미노출이라 직접 extern 선언(POSIX). 미참조 시 링크 제외.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn setEnv(key: [:0]const u8, value: [:0]const u8) void {
    if (builtin.os.tag != .windows) {
        _ = setenv(key.ptr, value.ptr, 1);
    }
    if (environ_map) |m| m.put(key, value) catch {};
}
