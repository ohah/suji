//! Embedded Python(python-build-standalone) 소스 계약 가드 — CEF/런타임 없이
//! build.zig / staging 스크립트 / CI / 예제 배선이 실수로 빠지지 않게 고정한다.
//! 실 런타임 왕복(Py init→invoke→json)은 src/platform/python.zig 의 인라인 test
//! (staged 일 때만) + tests/e2e/run-python-e2e.sh 가 검증한다.

const std = @import("std");

fn slurp(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20));
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    std.testing.expect(std.mem.indexOf(u8, hay, needle) != null) catch |err| {
        std.debug.print("missing substring: {s}\n", .{needle});
        return err;
    };
}

test "build.zig: Python staging + weak-link auto-detect + packaging install step" {
    const a = std.testing.allocator;
    const b = try slurp(a, "build.zig");
    defer a.free(b);
    // staging 경로(libnode 패턴) + auto-detect 게이트.
    try expectContains(b, ".suji/python/3.13.13");
    try expectContains(b, "python_available");
    // weak-link: python staging 머신 빌드여도 비-python 앱 graceful(심볼 null).
    try expectContains(b, "linkSystemLibrary(\"python3.13\", .{ .weak = true })");
    // Windows 는 MSVC import lib 게이트(node .dll.a 동형).
    try expectContains(b, "libs/python3.lib");
    // packaging: end-user 머신 Python 미설치 대응 — libpython+stdlib 동반.
    try expectContains(b, "addInstallPythonRuntimeStep");
}

test "scripts/stage-python.sh: install_only staging contract" {
    const a = std.testing.allocator;
    const s = try slurp(a, "scripts/stage-python.sh");
    defer a.free(s);
    try expectContains(s, "python-build-standalone");
    try expectContains(s, "install_only");
    try expectContains(s, "PYTHON_PBS_TAG");
    // install_only 타르볼 top-level `python/` 제거.
    try expectContains(s, "--strip-components=1");
}

test "CI / e2e workflows: Python staging + e2e wired" {
    const a = std.testing.allocator;
    const ci = try slurp(a, ".github/workflows/ci.yml");
    defer a.free(ci);
    try expectContains(ci, "stage-python.sh");
    const e2e = try slurp(a, ".github/workflows/e2e.yml");
    defer a.free(e2e);
    try expectContains(e2e, "run-python-e2e.sh");
}

test "examples: python-backend + multi-backend python 배선" {
    const a = std.testing.allocator;
    const single = try slurp(a, "examples/python-backend/suji.json");
    defer a.free(single);
    try expectContains(single, "\"lang\": \"python\"");
    const multi = try slurp(a, "examples/multi-backend/suji.json");
    defer a.free(multi);
    try expectContains(multi, "\"lang\": \"python\"");
}

test "e2e runner + test 존재 + python 채널" {
    const a = std.testing.allocator;
    const runner = try slurp(a, "tests/e2e/run-python-e2e.sh");
    defer a.free(runner);
    try expectContains(runner, "stage-python.sh");
    try expectContains(runner, "python-invoke.test.ts");
    const test_ts = try slurp(a, "tests/e2e/python-invoke.test.ts");
    defer a.free(test_ts);
    try expectContains(test_ts, "embedded CPython");
}
