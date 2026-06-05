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

// 모바일(iOS) Python 백엔드 소스 계약 — 실 기능 검증은 tests/mobile-backends/
// ios-e2e.sh python(시뮬레이터, Xcode 필요라 CI 외 로컬/수동, clipboard 모바일
// e2e 와 동일 바). 여기선 배선이 빠지지 않게 CEF/Xcode 없이 고정.
test "iOS Python 백엔드 배선 계약" {
    const a = std.testing.allocator;

    // staging: Python-Apple-support(PEP 730) iOS xcframework.
    const stage = try slurp(a, "scripts/stage-python-ios.sh");
    defer a.free(stage);
    try expectContains(stage, "Python-Apple-support");
    try expectContains(stage, "Python.xcframework");

    // backend.zig — 데스크탑 런타임 포팅 + 모바일 C ABI + outbound extern + 교훈.
    const backend = try slurp(a, "examples/ios/backends/python/src/backend.zig");
    defer a.free(backend);
    try expectContains(backend, "export fn suji_python_backend_start");
    try expectContains(backend, "export fn suji_python_backend_channels");
    try expectContains(backend, "export fn suji_python_backend_handle_ipc");
    try expectContains(backend, "extern fn suji_core_invoke"); // outbound 배선
    try expectContains(backend, "_Py_USE_GCC_BUILTIN_ATOMICS"); // pyatomic 회피
    try expectContains(backend, "PyObject_CallOneArg"); // non-variadic

    // build-lib: xcframework 헤더로 컴파일(libpython 은 앱 링크 해소).
    const bbuild = try slurp(a, "examples/ios/backends/python/build-lib.sh");
    defer a.free(bbuild);
    try expectContains(bbuild, "Python.xcframework");
    try expectContains(bbuild, "ios-sim");

    // 호스트 변형: bridging header + Backends.swift(start+channels) + project.yml(embed).
    const bridge = try slurp(a, "examples/ios/_shared/Suji-Bridging-Header.h");
    defer a.free(bridge);
    try expectContains(bridge, "suji_python_backend_start");
    const swift = try slurp(a, "examples/ios/python/Backends.swift");
    defer a.free(swift);
    try expectContains(swift, "suji_python_backend_start");
    try expectContains(swift, "suji_python_backend_channels");
    const proj = try slurp(a, "examples/ios/python/project.yml");
    defer a.free(proj);
    try expectContains(proj, "Python.xcframework");
    try expectContains(proj, "embed: true");
}
