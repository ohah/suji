const std = @import("std");
const builtin = @import("builtin");
const suji = @import("suji");

// autostart plugin — Tauri `@tauri-apps/plugin-autostart` 패리티. 로그인 시 앱 자동 실행.
//   autostart:enable / autostart:disable / autostart:isEnabled
// macOS: ~/Library/LaunchAgents/<label>.plist (LaunchAgent, RunAtLoad).
// Linux: ~/.config/autostart/<label>.desktop (XDG autostart).
// Windows/기타: 미지원 → {ok:false, supported:false} (정직 graceful).
//
// ⚠️ macOS 는 plist 작성/삭제만 — `launchctl load` 미호출이라 enable 은 다음 로그인부터
// 발효(즉시 등록은 launchctl 필요, 플러그인 컨텍스트에서 spawn 회피). label 기본 "suji-app".
pub const app = suji.app()
    .named("autostart")
    .handle("autostart:enable", enable)
    .handle("autostart:disable", disable)
    .handle("autostart:isEnabled", isEnabled);

var gpa: std.heap.DebugAllocator(.{}) = .init;
const alloc = gpa.allocator();
fn io() std.Io {
    return suji.io();
}

const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

fn cGetenv(n: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(n) orelse return null;
    return std.mem.span(raw);
}

/// label sanitize — path 분리자/traversal 차단.
fn sanitizeLabel(raw: ?[]const u8) []const u8 {
    const s = raw orelse return "suji-app";
    if (s.len == 0 or s.len > 128) return "suji-app";
    if (std.mem.indexOf(u8, s, "..") != null) return "suji-app";
    for (s) |c| {
        if (c == '/' or c == '\\' or c == 0) return "suji-app";
    }
    return s;
}

/// autostart 항목 파일 경로 (arena 할당). 미지원 OS 면 null.
fn entryPath(arena: std.mem.Allocator, label: []const u8) ?[]const u8 {
    const home = cGetenv("HOME") orelse return null;
    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(arena, "{s}/Library/LaunchAgents/{s}.plist", .{ home, label }) catch null;
    } else if (builtin.os.tag == .linux) {
        if (cGetenv("XDG_CONFIG_HOME")) |cfg| {
            return std.fmt.allocPrint(arena, "{s}/autostart/{s}.desktop", .{ cfg, label }) catch null;
        }
        return std.fmt.allocPrint(arena, "{s}/.config/autostart/{s}.desktop", .{ home, label }) catch null;
    }
    return null;
}

fn selfExe(buf: []u8) ?[]const u8 {
    const n = std.process.executablePath(io(), buf) catch return null;
    return buf[0..n];
}

fn entryContent(arena: std.mem.Allocator, label: []const u8, exe: []const u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(arena,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>Label</key><string>{s}</string>
            \\  <key>ProgramArguments</key><array><string>{s}</string></array>
            \\  <key>RunAtLoad</key><true/>
            \\</dict>
            \\</plist>
            \\
        , .{ label, exe }) catch null;
    } else if (builtin.os.tag == .linux) {
        return std.fmt.allocPrint(arena,
            \\[Desktop Entry]
            \\Type=Application
            \\Name={s}
            \\Exec={s}
            \\X-GNOME-Autostart-enabled=true
            \\
        , .{ label, exe }) catch null;
    }
    return null;
}

fn unsupported(req: suji.Request) suji.Response {
    return req.okRaw("{\"ok\":false,\"supported\":false}");
}

fn enable(req: suji.Request) suji.Response {
    if (!supported) return unsupported(req);
    const label = sanitizeLabel(req.string("label"));
    const path = entryPath(req.arena, label) orelse return req.err("no home");
    var exe_buf: [4096]u8 = undefined;
    const exe = selfExe(&exe_buf) orelse return req.err("cannot resolve exe");
    const content = entryContent(req.arena, label, exe) orelse return req.err("format error");

    // 디렉토리 생성 (LaunchAgents / autostart).
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        std.Io.Dir.cwd().createDirPath(io(), path[0..sep]) catch {};
    }
    var file = std.Io.Dir.cwd().createFile(io(), path, .{}) catch return req.err("write failed");
    defer file.close(io());
    var fw_buf: [1024]u8 = undefined;
    var fw = file.writer(io(), &fw_buf);
    fw.interface.writeAll(content) catch return req.err("write failed");
    fw.interface.flush() catch return req.err("write failed");
    return req.okRaw("{\"ok\":true,\"supported\":true}");
}

fn disable(req: suji.Request) suji.Response {
    if (!supported) return unsupported(req);
    const label = sanitizeLabel(req.string("label"));
    const path = entryPath(req.arena, label) orelse return req.err("no home");
    std.Io.Dir.cwd().deleteFile(io(), path) catch {}; // 부재면 멱등 no-op
    return req.okRaw("{\"ok\":true,\"supported\":true}");
}

fn isEnabled(req: suji.Request) suji.Response {
    if (!supported) return req.okRaw("{\"enabled\":false,\"supported\":false}");
    const label = sanitizeLabel(req.string("label"));
    const path = entryPath(req.arena, label) orelse return req.okRaw("{\"enabled\":false,\"supported\":true}");
    var f = std.Io.Dir.cwd().openFile(io(), path, .{}) catch {
        return req.okRaw("{\"enabled\":false,\"supported\":true}");
    };
    f.close(io());
    return req.okRaw("{\"enabled\":true,\"supported\":true}");
}

comptime {
    _ = suji.exportApp(app);
}
