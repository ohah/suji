//! 비-macOS safeStorage 패리티 (macOS 는 cef.zig Keychain).
//! - Linux : `secret-tool`(libsecret CLI) — Electron 과 동일 Secret Service.
//!           C ABI/링크 불필요(서브프로세스), service/account attribute 키.
//! - Windows: DPAPI `CryptProtectData`/`CryptUnprotectData`(crypt32) 로
//!           암호화 후 `%LOCALAPPDATA%\suji\safe_storage\<hex>.bin` 저장
//!           (DPAPI 는 키스토어가 아니라 암호화만 — 백킹 파일은 앱 소유).
//! 반환 규약은 cef.zig 의 macOS 구현과 동일(set/delete: bool, get: out_buf
//! slice — 없으면 길이 0).
const std = @import("std");
const builtin = @import("builtin");

// ── Linux: secret-tool 서브프로세스 ───────────────────────────────────
const linux_impl = struct {
    fn run(argv: []const []const u8, stdin_data: ?[]const u8, out_buf: ?[]u8) ?usize {
        var child = std.process.Child.init(argv, std.heap.page_allocator);
        child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
        child.stdout_behavior = if (out_buf != null) .Pipe else .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return null;
        if (stdin_data) |d| {
            if (child.stdin) |*sin| {
                sin.writeAll(d) catch {};
                sin.close();
                child.stdin = null;
            }
        }
        var n: usize = 0;
        if (out_buf) |ob| {
            if (child.stdout) |sout| n = sout.readAll(ob) catch 0;
        }
        const term = child.wait() catch return null;
        switch (term) {
            .Exited => |c| if (c != 0) return null,
            else => return null,
        }
        return n;
    }

    fn label(buf: []u8, service: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "suji:{s}", .{service}) catch "suji";
    }

    pub fn set(service: []const u8, account: []const u8, value: []const u8) bool {
        var lbuf: [320]u8 = undefined;
        return run(&.{
            "secret-tool", "store", "--label", label(&lbuf, service),
            "service",     service, "account", account,
        }, value, null) != null;
    }

    pub fn get(service: []const u8, account: []const u8, out_buf: []u8) []const u8 {
        const n = run(&.{ "secret-tool", "lookup", "service", service, "account", account }, null, out_buf) orelse return out_buf[0..0];
        // secret-tool lookup 은 값 끝에 개행 1개 부가 — 제거.
        var len = n;
        if (len > 0 and out_buf[len - 1] == '\n') len -= 1;
        return out_buf[0..len];
    }

    pub fn delete(service: []const u8, account: []const u8) bool {
        return run(&.{ "secret-tool", "clear", "service", service, "account", account }, null, null) != null;
    }
};

// ── Windows: DPAPI + 백킹 파일 ────────────────────────────────────────
const win_impl = struct {
    const DATA_BLOB = extern struct { cbData: u32, pbData: ?[*]u8 };
    extern "crypt32" fn CryptProtectData(
        pDataIn: *DATA_BLOB,
        szDataDescr: ?[*:0]const u16,
        pOptionalEntropy: ?*DATA_BLOB,
        pvReserved: ?*anyopaque,
        pPromptStruct: ?*anyopaque,
        dwFlags: u32,
        pDataOut: *DATA_BLOB,
    ) callconv(.winapi) c_int;
    extern "crypt32" fn CryptUnprotectData(
        pDataIn: *DATA_BLOB,
        ppszDataDescr: ?*?[*:0]u16,
        pOptionalEntropy: ?*DATA_BLOB,
        pvReserved: ?*anyopaque,
        pPromptStruct: ?*anyopaque,
        dwFlags: u32,
        pDataOut: *DATA_BLOB,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

    /// %LOCALAPPDATA%\suji\safe_storage\<hex(service)>_<hex(account)>.bin
    fn pathFor(buf: []u8, service: []const u8, account: []const u8) ?[]const u8 {
        const base = std.process.getEnvVarOwned(std.heap.page_allocator, "LOCALAPPDATA") catch return null;
        defer std.heap.page_allocator.free(base);
        const dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}\\suji\\safe_storage", .{base}) catch return null;
        defer std.heap.page_allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};
        var name: [1024]u8 = undefined;
        var w: usize = 0;
        for (service) |c| {
            w += (std.fmt.bufPrint(name[w..], "{x:0>2}", .{c}) catch return null).len;
        }
        name[w] = '_';
        w += 1;
        for (account) |c| {
            w += (std.fmt.bufPrint(name[w..], "{x:0>2}", .{c}) catch return null).len;
        }
        return std.fmt.bufPrint(buf, "{s}\\{s}.bin", .{ dir, name[0..w] }) catch null;
    }

    pub fn set(service: []const u8, account: []const u8, value: []const u8) bool {
        var pbuf: [1280]u8 = undefined;
        const path = pathFor(&pbuf, service, account) orelse return false;
        var in_blob = DATA_BLOB{ .cbData = @intCast(value.len), .pbData = @constCast(value.ptr) };
        var out_blob = DATA_BLOB{ .cbData = 0, .pbData = null };
        if (CryptProtectData(&in_blob, null, null, null, null, 0, &out_blob) == 0) return false;
        defer _ = LocalFree(out_blob.pbData);
        const enc = (out_blob.pbData orelse return false)[0..out_blob.cbData];
        const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
        defer f.close();
        f.writeAll(enc) catch return false;
        return true;
    }

    pub fn get(service: []const u8, account: []const u8, out_buf: []u8) []const u8 {
        var pbuf: [1280]u8 = undefined;
        const path = pathFor(&pbuf, service, account) orelse return out_buf[0..0];
        const f = std.fs.cwd().openFile(path, .{}) catch return out_buf[0..0];
        defer f.close();
        var enc: [8192]u8 = undefined;
        const elen = f.readAll(&enc) catch return out_buf[0..0];
        var in_blob = DATA_BLOB{ .cbData = @intCast(elen), .pbData = &enc };
        var out_blob = DATA_BLOB{ .cbData = 0, .pbData = null };
        if (CryptUnprotectData(&in_blob, null, null, null, null, 0, &out_blob) == 0) return out_buf[0..0];
        defer _ = LocalFree(out_blob.pbData);
        const dec = (out_blob.pbData orelse return out_buf[0..0])[0..out_blob.cbData];
        const n = @min(dec.len, out_buf.len);
        @memcpy(out_buf[0..n], dec[0..n]);
        return out_buf[0..n];
    }

    pub fn delete(service: []const u8, account: []const u8) bool {
        var pbuf: [1280]u8 = undefined;
        const path = pathFor(&pbuf, service, account) orelse return false;
        std.fs.cwd().deleteFile(path) catch return false;
        return true;
    }
};

const impl = switch (builtin.os.tag) {
    .linux => linux_impl,
    .windows => win_impl,
    else => @compileError("safe_storage_os: macOS 는 cef.zig Keychain 사용"),
};

pub fn set(service: []const u8, account: []const u8, value: []const u8) bool {
    return impl.set(service, account, value);
}
pub fn get(service: []const u8, account: []const u8, out_buf: []u8) []const u8 {
    return impl.get(service, account, out_buf);
}
pub fn delete(service: []const u8, account: []const u8) bool {
    return impl.delete(service, account);
}
