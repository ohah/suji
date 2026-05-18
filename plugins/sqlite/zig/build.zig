const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const util_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/core/util.zig"),
        .target = target,
        .optimize = optimize,
    });

    const suji_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/core/app.zig"),
        .target = target,
        .optimize = optimize,
    });
    suji_mod.addImport("util", util_mod);

    const lib = b.addLibrary(.{
        .name = "backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .dynamic,
    });
    lib.root_module.addImport("suji", suji_mod);

    // Vendored SQLite amalgamation (vendor/README.md — 3.51.0, public domain).
    // 컴파일 옵션: THREADSAFE=1(직렬화 — 플러그인 글로벌 뮤텍스가 이미 모든
    // 호출을 직렬화하므로 sqlite 내부 락은 무경합이라 비용 무의미. =2 로
    // 바꾸면 글로벌 뮤텍스 제거/per-db 락 도입 같은 후속 변경에서 조용한
    // data-race 가 되므로 robust-by-construction 한 =1 유지), DQS=0(이중따옴표
    // string literal 금지 — 표준 SQL), FK 기본 ON, 미사용/deprecated 제거.
    lib.root_module.addIncludePath(b.path("vendor"));
    lib.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_USE_URI=0",
            "-std=c99",
        },
    });

    b.installArtifact(lib);
}
