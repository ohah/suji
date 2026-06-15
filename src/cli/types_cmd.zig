const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const suji = @import("../root.zig");
const backend_build = @import("../core/backend_build.zig");
const loader = @import("loader");

/// `suji types [--out <path>]` — zig 백엔드의 `.schema()` 체인을 SujiHandlers
/// `.d.ts` 로 자동 생성(수동 augment 불요). 빌드→dlopen→`backend_dump_schema`.
/// zig 백엔드만 — Rust=specta 수동/Go·Node=수동 augment(정직 한계, 후속).
/// dlopen 은 loader.DynLib(POSIX std.DynLib / Windows kernel32 WinDynLib) — Windows
/// 도 backend .dll 로드 가능(이전엔 std.DynLib Windows 부재로 차단했었음).
fn dumpZigSchema(allocator: std.mem.Allocator, entry: []const u8, out: *std.ArrayList(u8)) void {
    backend_build.buildByLang(allocator, "zig", entry, false) catch |err| {
        std.debug.print("[suji types] {s} 빌드 실패: {}\n", .{ entry, err });
        return;
    };
    const path = backend_build.dylibPath(allocator, "zig", entry, false) catch return;
    defer allocator.free(path);
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);
    var lib = loader.DynLib.open(path_z) catch |err| {
        std.debug.print("[suji types] dlopen 실패 {s}: {}\n", .{ path, err });
        return;
    };
    defer lib.close();
    const DumpFn = *const fn () callconv(.c) ?[*:0]u8;
    const dump = lib.lookup(DumpFn, "backend_dump_schema") orelse {
        std.debug.print("[suji types] backend_dump_schema 심볼 없음 (구버전 SDK?)\n", .{});
        return;
    };
    const s = dump() orelse {
        std.debug.print("[suji types] {s}: `.schema()` 미등록 — 수동 augment 폴백(docs)\n", .{entry});
        return;
    };
    out.appendSlice(allocator, std.mem.span(s)) catch {};
}

/// 백엔드 1개 → zig 면 schema dump, 아니면 정직 skip(Rust=specta 수동 등).
/// 단일/배열 config 분기에서 공용(중복 제거).
fn oneBackend(allocator: std.mem.Allocator, lang: []const u8, entry: []const u8, out: *std.ArrayList(u8)) void {
    if (std.mem.eql(u8, lang, "zig")) {
        dumpZigSchema(allocator, entry, out);
    } else {
        std.debug.print("[suji types] {s} 백엔드 schema 추출 미지원 — 수동 augment(Rust=specta)\n", .{lang});
    }
}

pub fn run(allocator: std.mem.Allocator, types_args: []const [:0]const u8) !void {
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < types_args.len) : (i += 1) {
        if (std.mem.eql(u8, types_args[i], "--out") and i + 1 < types_args.len) {
            out_path = types_args[i + 1];
            i += 1;
        }
    }

    var config = suji.Config.load(allocator) catch {
        std.debug.print("Error: suji.json not found (프로젝트 루트에서 실행).\n", .{});
        return;
    };
    defer config.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (config.backends) |backends| {
        for (backends) |be| oneBackend(allocator, be.lang, be.entry, &out);
    } else if (config.backend) |be| {
        oneBackend(allocator, be.lang, be.entry, &out);
    }

    if (out.items.len == 0) {
        std.debug.print("[suji types] 생성할 schema 없음 (zig 백엔드 + `.schema()` 필요).\n", .{});
        return;
    }
    // 생성된 .d.ts 는 stdout(`suji types > suji.d.ts`) 또는 --out 파일. 진단/빌드로그는
    // std.debug.print=stderr 라 .d.ts 와 안 섞임. stdout 은 std.Io.File.stdout()(크로스
    // 플랫폼 — 이전 `/dev/stdout` 은 POSIX 전용이라 Windows 차단 사유였음). stdout 은
    // 프로세스 핸들이라 close 하지 않는다(파일만 close).
    var wbuf: [4096]u8 = undefined;
    if (out_path) |p| {
        const f = std.Io.Dir.cwd().createFile(runtime.io, p, .{}) catch |err| {
            std.debug.print("[suji types] {s} 쓰기 실패: {}\n", .{ p, err });
            return;
        };
        defer f.close(runtime.io);
        var fw = f.writer(runtime.io, &wbuf);
        fw.interface.writeAll(out.items) catch return;
        fw.interface.flush() catch return;
        std.debug.print("[suji types] → {s} ({d} bytes)\n", .{ p, out.items.len });
    } else {
        var fw = std.Io.File.stdout().writer(runtime.io, &wbuf);
        fw.interface.writeAll(out.items) catch return;
        fw.interface.flush() catch return;
    }
}
