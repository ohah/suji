//! safeStorage — cef.zig 에서 분리(동작 무변경). macOS Keychain,
//! Linux libsecret/Secret Service, Windows Credential Manager bridge.
const std = @import("std");
const builtin = @import("builtin");
const safe_storage = @import("safe_storage.zig");
const cef = @import("cef.zig");

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

const getClass = cef.getClass;
const msgSend = cef.msgSend;
const msgSendVoid2 = cef.msgSendVoid2;
const nsStringFromSlice = cef.nsStringFromSlice;
const CFDataCreate = cef.CFDataCreate;
const CFDataGetBytePtr = cef.CFDataGetBytePtr;
const CFDataGetLength = cef.CFDataGetLength;
const CFRelease = cef.CFRelease;

// SecItemAdd / SecItemCopyMatching / SecItemDelete — generic password class.
// service = "Suji" + 사용자 지정 namespace, account = key. value는 plain UTF-8.
// macOS Keychain이 자동 암호화 — 사용자 login session 잠금 시 OS가 access 차단.

extern "c" const kSecClass: ?*anyopaque;
extern "c" const kSecClassGenericPassword: ?*anyopaque;
extern "c" const kSecAttrService: ?*anyopaque;
extern "c" const kSecAttrAccount: ?*anyopaque;
extern "c" const kSecValueData: ?*anyopaque;
extern "c" const kSecReturnData: ?*anyopaque;
extern "c" const kSecMatchLimit: ?*anyopaque;
extern "c" const kSecMatchLimitOne: ?*anyopaque;
extern "c" const kCFBooleanTrue: ?*anyopaque;

extern "c" fn SecItemAdd(attributes: ?*anyopaque, result: ?*?*anyopaque) c_int;
extern "c" fn SecItemUpdate(query: ?*anyopaque, attributes_to_update: ?*anyopaque) c_int;
extern "c" fn SecItemCopyMatching(query: ?*anyopaque, result: ?*?*anyopaque) c_int;
extern "c" fn SecItemDelete(query: ?*anyopaque) c_int;

const errSecSuccess: c_int = 0;
const errSecItemNotFound: c_int = -25300;
const errSecDuplicateItem: c_int = -25299;

const win_cred = if (is_windows) struct {
    const w = std.os.windows;

    const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };

    const CREDENTIALW = extern struct {
        Flags: u32,
        Type: u32,
        TargetName: ?[*:0]u16,
        Comment: ?[*:0]u16,
        LastWritten: FILETIME,
        CredentialBlobSize: u32,
        CredentialBlob: ?[*]u8,
        Persist: u32,
        AttributeCount: u32,
        Attributes: ?*anyopaque,
        TargetAlias: ?[*:0]u16,
        UserName: ?[*:0]u16,
    };

    extern "advapi32" fn CredWriteW(Credential: *const CREDENTIALW, Flags: u32) callconv(.winapi) w.BOOL;
    extern "advapi32" fn CredReadW(TargetName: [*:0]const u16, Type: u32, Flags: u32, Credential: *?*CREDENTIALW) callconv(.winapi) w.BOOL;
    extern "advapi32" fn CredDeleteW(TargetName: [*:0]const u16, Type: u32, Flags: u32) callconv(.winapi) w.BOOL;
    extern "advapi32" fn CredFree(Buffer: ?*anyopaque) callconv(.winapi) void;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    const CRED_TYPE_GENERIC: u32 = 1;
    const CRED_PERSIST_LOCAL_MACHINE: u32 = 2;
    const ERROR_NOT_FOUND: u32 = 1168;
} else struct {};

const linux_secret = if (is_linux) struct {
    const SecretSchemaAttribute = extern struct {
        name: ?[*:0]const u8,
        type: c_int,
    };

    const SecretSchema = extern struct {
        name: [*:0]const u8,
        flags: c_int,
        attributes: [32]SecretSchemaAttribute,
        reserved: c_int,
        reserved1: ?*anyopaque,
        reserved2: ?*anyopaque,
        reserved3: ?*anyopaque,
        reserved4: ?*anyopaque,
        reserved5: ?*anyopaque,
        reserved6: ?*anyopaque,
        reserved7: ?*anyopaque,
    };

    extern "c" fn secret_password_store_sync(schema: *const SecretSchema, collection: ?[*:0]const u8, label: [*:0]const u8, password: [*:0]const u8, cancellable: ?*anyopaque, err: ?*?*anyopaque, ...) callconv(.c) c_int;
    extern "c" fn secret_password_lookup_sync(schema: *const SecretSchema, cancellable: ?*anyopaque, err: ?*?*anyopaque, ...) callconv(.c) ?[*:0]u8;
    extern "c" fn secret_password_clear_sync(schema: *const SecretSchema, cancellable: ?*anyopaque, err: ?*?*anyopaque, ...) callconv(.c) c_int;
    extern "c" fn secret_password_free(password: ?[*:0]u8) callconv(.c) void;
    extern "c" fn g_error_free(err: ?*anyopaque) callconv(.c) void;

    const SECRET_SCHEMA_NONE: c_int = 0;
    const SECRET_SCHEMA_ATTRIBUTE_STRING: c_int = 0;
    const attr_service: [*:0]const u8 = "service";
    const attr_account: [*:0]const u8 = "account";
    const attr_end: ?[*:0]const u8 = null;

    const schema = SecretSchema{
        .name = "dev.suji.SafeStorage",
        .flags = SECRET_SCHEMA_NONE,
        .attributes = init_attrs: {
            var attrs = [_]SecretSchemaAttribute{.{ .name = null, .type = 0 }} ** 32;
            attrs[0] = .{ .name = "service", .type = SECRET_SCHEMA_ATTRIBUTE_STRING };
            attrs[1] = .{ .name = "account", .type = SECRET_SCHEMA_ATTRIBUTE_STRING };
            break :init_attrs attrs;
        },
        .reserved = 0,
        .reserved1 = null,
        .reserved2 = null,
        .reserved3 = null,
        .reserved4 = null,
        .reserved5 = null,
        .reserved6 = null,
        .reserved7 = null,
    };

    fn freeError(err: ?*anyopaque) void {
        if (err) |e| g_error_free(e);
    }
} else struct {};

/// service/account/class 3개 필드를 가진 NSMutableDictionary (NSDictionary ↔ CFDictionary toll-free bridged).
fn buildKeychainQuery(class_val: ?*anyopaque, service: []const u8, account: []const u8) ?*anyopaque {
    const NSMutableDictionary = getClass("NSMutableDictionary") orelse return null;
    const dict = msgSend(NSMutableDictionary, "dictionary") orelse return null;
    msgSendVoid2(dict, "setObject:forKey:", class_val, kSecClass);
    if (nsStringFromSlice(service)) |s| msgSendVoid2(dict, "setObject:forKey:", s, kSecAttrService);
    if (nsStringFromSlice(account)) |a| msgSendVoid2(dict, "setObject:forKey:", a, kSecAttrAccount);
    return dict;
}

/// 키체인에 utf-8 값을 저장. 같은 key가 있으면 update. 성공 = true.
/// Add → DuplicateItem이면 Update fallback — race-free + 1 syscall (Apple 권장 패턴).
pub fn safeStorageSet(service: []const u8, account: []const u8, value: []const u8) bool {
    if (comptime is_linux) {
        var service_buf: [512]u8 = undefined;
        var account_buf: [512]u8 = undefined;
        var value_buf: [1024]u8 = undefined;
        var label_buf: [256]u8 = undefined;
        const service_z = safe_storage.copyToSentinel(&service_buf, service) orelse return false;
        const account_z = safe_storage.copyToSentinel(&account_buf, account) orelse return false;
        const value_z = safe_storage.copyToSentinel(&value_buf, value) orelse return false;
        const label = safe_storage.buildLabel(&label_buf, service, account) orelse return false;
        var err: ?*anyopaque = null;
        const ok = linux_secret.secret_password_store_sync(
            &linux_secret.schema,
            null,
            label.ptr,
            value_z.ptr,
            null,
            &err,
            linux_secret.attr_service,
            service_z.ptr,
            linux_secret.attr_account,
            account_z.ptr,
            linux_secret.attr_end,
        ) != 0;
        linux_secret.freeError(err);
        return ok;
    }

    if (comptime is_windows) {
        var target_buf: [1024]u16 = undefined;
        const target = safe_storage.buildTargetUtf16(&target_buf, service, account) orelse return false;
        var credential = win_cred.CREDENTIALW{
            .Flags = 0,
            .Type = win_cred.CRED_TYPE_GENERIC,
            .TargetName = target.ptr,
            .Comment = null,
            .LastWritten = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 },
            .CredentialBlobSize = @intCast(value.len),
            .CredentialBlob = if (value.len == 0) null else @constCast(value.ptr),
            .Persist = win_cred.CRED_PERSIST_LOCAL_MACHINE,
            .AttributeCount = 0,
            .Attributes = null,
            .TargetAlias = null,
            .UserName = target.ptr,
        };
        return win_cred.CredWriteW(&credential, 0).toBool();
    }

    if (!comptime is_macos) return false;
    const query = buildKeychainQuery(kSecClassGenericPassword, service, account) orelse return false;
    const data = CFDataCreate(null, value.ptr, @intCast(value.len)) orelse return false;
    defer CFRelease(data);

    msgSendVoid2(query, "setObject:forKey:", data, kSecValueData);
    const r = SecItemAdd(query, null);
    if (r == errSecSuccess) return true;
    if (r != errSecDuplicateItem) return false;

    // 이미 존재 — Update. update_attrs는 새 value만 (query는 kSecValueData 없는 lookup용).
    const NSMutableDictionary = getClass("NSMutableDictionary") orelse return false;
    const update_attrs = msgSend(NSMutableDictionary, "dictionary") orelse return false;
    msgSendVoid2(update_attrs, "setObject:forKey:", data, kSecValueData);

    const lookup = buildKeychainQuery(kSecClassGenericPassword, service, account) orelse return false;
    return SecItemUpdate(lookup, update_attrs) == errSecSuccess;
}

/// 키체인에서 utf-8 값 read. out_buf에 복사 후 length 반환. 못 찾으면 빈 slice.
pub fn safeStorageGet(service: []const u8, account: []const u8, out_buf: []u8) []const u8 {
    if (comptime is_linux) {
        var service_buf: [512]u8 = undefined;
        var account_buf: [512]u8 = undefined;
        const service_z = safe_storage.copyToSentinel(&service_buf, service) orelse return out_buf[0..0];
        const account_z = safe_storage.copyToSentinel(&account_buf, account) orelse return out_buf[0..0];
        var err: ?*anyopaque = null;
        const password = linux_secret.secret_password_lookup_sync(
            &linux_secret.schema,
            null,
            &err,
            linux_secret.attr_service,
            service_z.ptr,
            linux_secret.attr_account,
            account_z.ptr,
            linux_secret.attr_end,
        );
        linux_secret.freeError(err);
        const password_z = password orelse return out_buf[0..0];
        defer linux_secret.secret_password_free(password_z);

        const len = std.mem.len(password_z);
        const n = @min(len, out_buf.len);
        @memcpy(out_buf[0..n], password_z[0..n]);
        return out_buf[0..n];
    }

    if (comptime is_windows) {
        var target_buf: [1024]u16 = undefined;
        const target = safe_storage.buildTargetUtf16(&target_buf, service, account) orelse return out_buf[0..0];
        var credential: ?*win_cred.CREDENTIALW = null;
        if (!win_cred.CredReadW(target.ptr, win_cred.CRED_TYPE_GENERIC, 0, &credential).toBool()) return out_buf[0..0];
        const cred = credential orelse return out_buf[0..0];
        defer win_cred.CredFree(cred);

        const blob = cred.CredentialBlob orelse return out_buf[0..0];
        const len: usize = @intCast(cred.CredentialBlobSize);
        const n = @min(len, out_buf.len);
        @memcpy(out_buf[0..n], blob[0..n]);
        return out_buf[0..n];
    }

    if (!comptime is_macos) return out_buf[0..0];
    const query = buildKeychainQuery(kSecClassGenericPassword, service, account) orelse return out_buf[0..0];
    msgSendVoid2(query, "setObject:forKey:", kCFBooleanTrue, kSecReturnData);
    msgSendVoid2(query, "setObject:forKey:", kSecMatchLimitOne, kSecMatchLimit);

    var result: ?*anyopaque = null;
    if (SecItemCopyMatching(query, &result) != errSecSuccess) return out_buf[0..0];
    const data = result orelse return out_buf[0..0];
    defer CFRelease(data);

    const ptr = CFDataGetBytePtr(data);
    const len: usize = @intCast(CFDataGetLength(data));
    const n = @min(len, out_buf.len);
    @memcpy(out_buf[0..n], ptr[0..n]);
    return out_buf[0..n];
}

pub fn safeStorageDelete(service: []const u8, account: []const u8) bool {
    if (comptime is_linux) {
        var service_buf: [512]u8 = undefined;
        var account_buf: [512]u8 = undefined;
        const service_z = safe_storage.copyToSentinel(&service_buf, service) orelse return false;
        const account_z = safe_storage.copyToSentinel(&account_buf, account) orelse return false;
        var err: ?*anyopaque = null;
        _ = linux_secret.secret_password_clear_sync(
            &linux_secret.schema,
            null,
            &err,
            linux_secret.attr_service,
            service_z.ptr,
            linux_secret.attr_account,
            account_z.ptr,
            linux_secret.attr_end,
        );
        const had_error = err != null;
        linux_secret.freeError(err);
        return !had_error;
    }

    if (comptime is_windows) {
        var target_buf: [1024]u16 = undefined;
        const target = safe_storage.buildTargetUtf16(&target_buf, service, account) orelse return false;
        if (win_cred.CredDeleteW(target.ptr, win_cred.CRED_TYPE_GENERIC, 0).toBool()) return true;
        return win_cred.GetLastError() == win_cred.ERROR_NOT_FOUND;
    }

    if (!comptime is_macos) return false;
    const query = buildKeychainQuery(kSecClassGenericPassword, service, account) orelse return false;
    const r = SecItemDelete(query);
    return r == errSecSuccess or r == errSecItemNotFound;
}
