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
    // 버전 단일 출처 상수 + auto-detect 게이트. (staging 경로는 `{s}/.suji/python/{s}`
    // 포맷 + python_version 상수로 조립되므로 리터럴 풀패스가 아니라 **상수**를 검사 —
    // 버전 bump 시 build.zig 한 곳만 바뀌고 이 계약은 그대로 따라온다.)
    try expectContains(b, "python_version = \"3.13.13\"");
    try expectContains(b, "python_available");
    // weak-link: python staging 머신 빌드여도 비-python 앱 graceful(심볼 null).
    // 링크 대상은 python_minor 파생(`python{s}`) — 버전 상수 단일 출처.
    try expectContains(b, "\"python{s}\", .{python_minor}");
    try expectContains(b, ".{ .weak = true }");
    // Windows 는 MSVC import lib 게이트(node .dll.a 동형) — python_abi 파생(python313.lib).
    try expectContains(b, "libs/python{s}.lib");
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

// 모바일(Android) Python 백엔드 소스 계약 — 실 기능 검증은 tests/mobile-backends/
// android-e2e.sh python(에뮬레이터, NDK/SDK/JDK 필요라 CI 외 로컬/수동). iOS 와
// 달리 prebuilt 3.13 Android 가 없어 NDK 소스 크로스빌드(stage-python-android.sh)
// + zig translate-c 가 NDK bionic 을 못 풀어 백엔드는 C(backend_android.c, NDK clang).
test "Android Python 백엔드 배선 계약" {
    const a = std.testing.allocator;

    // staging: CPython NDK 크로스빌드(소스).
    const stage = try slurp(a, "scripts/stage-python-android.sh");
    defer a.free(stage);
    try expectContains(stage, "android.py");
    try expectContains(stage, "make-host");

    // backend_android.c — iOS backend.zig 동일 로직의 C 포팅(NDK clang, translate-c 회피).
    const backend = try slurp(a, "examples/ios/backends/python/src/backend_android.c");
    defer a.free(backend);
    try expectContains(backend, "suji_python_backend_start");
    try expectContains(backend, "suji_python_backend_channels");
    try expectContains(backend, "suji_python_backend_handle_ipc");
    try expectContains(backend, "suji_core_invoke"); // outbound
    try expectContains(backend, "PyImport_AppendInittab");

    // 변형 build-lib: NDK clang 컴파일 + libpython.so + stdlib zip.
    const bl = try slurp(a, "examples/android/python/build-lib.sh");
    defer a.free(bl);
    try expectContains(bl, "backend_android.c");
    try expectContains(bl, "libpython3.13.so");
    try expectContains(bl, "python-stdlib.zip");

    // JNI 등록: start + channels 파싱 → suji_reg_backend.
    const jni = try slurp(a, "examples/android/python/cpp/backends.c");
    defer a.free(jni);
    try expectContains(jni, "nativeRegisterPythonBackend");
    try expectContains(jni, "suji_python_backend_start");
    try expectContains(jni, "suji_reg_backend");

    // CMake: libpython SHARED IMPORTED. app: assets ../assets.
    const cmake = try slurp(a, "examples/android/python/cpp/CMakeLists.txt");
    defer a.free(cmake);
    try expectContains(cmake, "libpython");
    const gradle = try slurp(a, "examples/android/python/app/build.gradle");
    defer a.free(gradle);
    try expectContains(gradle, "../assets");

    // 공유 호스트 훅(게이트): MainActivity 추출 + SujiCore native 선언.
    const main = try slurp(a, "examples/android/_shared/java/dev/suji/examples/android/MainActivity.kt");
    defer a.free(main);
    try expectContains(main, "maybeStartPython");
    const core = try slurp(a, "examples/android/_shared/java/dev/suji/examples/android/SujiCore.kt");
    defer a.free(core);
    try expectContains(core, "nativeRegisterPythonBackend");
}

// CEF-free 호스트 하니스(tests/mobile-backends/run.sh, CI 포함)가 모바일 python
// 백엔드(backend_android.c)를 호스트 타깃으로 빌드·링크해 ping/echo 왕복까지
// **CI 자동** 검증한다. iOS/Android e2e 는 sim/emu 필요라 CI 외 → 이 host 경로가
// 모바일 python 의 유일한 CI 자동 기능 커버리지(sqlite 동급). 미staging 시 graceful skip.
test "host harness(run.sh): 모바일 python ping/echo CI 자동 검증 배선" {
    const a = std.testing.allocator;

    const run = try slurp(a, "tests/mobile-backends/run.sh");
    defer a.free(run);
    try expectContains(run, "backend_android.c"); // 호스트 타깃 컴파일
    try expectContains(run, "-DSUJI_HAVE_PYTHON"); // verify.c python 케이스 게이트
    try expectContains(run, "-lpython3.13"); // desktop libpython 링크
    try expectContains(run, "SUJI_PY_MAIN"); // main.py 경로 주입

    const verify = try slurp(a, "tests/mobile-backends/verify.c");
    defer a.free(verify);
    try expectContains(verify, "SUJI_HAVE_PYTHON"); // 미staging 환경 무참조 가드
    try expectContains(verify, "suji_python_backend_start");
    try expectContains(verify, "python ping (embedded CPython)");

    // CI mobile-backends job 이 run.sh 전에 libpython 을 staging.
    const ci = try slurp(a, ".github/workflows/ci.yml");
    defer a.free(ci);
    try expectContains(ci, "Stage embedded CPython");
}
