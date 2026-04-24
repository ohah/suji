//! WindowManager: 멀티 윈도우의 메모리/정책 관리자.
//!
//! 설계 원칙 (docs/WINDOW_API.md 참조):
//! - id 기반 API, monotonic u32 (재사용 없음)
//! - name 중복 시 singleton (forceNew=true면 신규)
//! - destroyed 창에 메서드 호출 시 error.WindowDestroyed
//! - 플랫폼 조작은 Native vtable로 위임 → WindowManager는 CEF 없이 TDD 가능
//!
//! Phase 2 단위 테스트는 `tests/window_manager_test.zig` 참조.
//! 실제 CEF 통합은 `src/platform/cef.zig`의 CefNative가 VTable 구현.

const std = @import("std");

pub const Bounds = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 800,
    height: u32 = 600,
};

pub const State = packed struct {
    visible: bool = true,
    focused: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
};

pub const CreateOptions = struct {
    name: ?[]const u8 = null,
    title: []const u8 = "Suji",
    bounds: Bounds = .{},
    parent_id: ?u32 = null,
    /// name 중복 시: false면 기존 id 반환(싱글턴), true면 새 창 생성
    force_new: bool = false,
};

pub const Window = struct {
    id: u32,
    /// 플랫폼 native handle (NSWindow*, HWND, GtkWindow* 또는 테스트에선 임의 값)
    native_handle: u64,
    /// owned string (WindowManager.allocator 소유). null이면 이름 없는 창
    name: ?[]const u8,
    /// owned string
    title: []const u8,
    bounds: Bounds,
    parent_id: ?u32,
    state: State,
    destroyed: bool = false,
};

/// 플랫폼 조작을 위임하는 추상화. CefNative가 CEF로 구현, TestNative가 stub.
pub const Native = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque = null,

    pub const VTable = struct {
        create_window: *const fn (ctx: ?*anyopaque, opts: *const CreateOptions) anyerror!u64,
        destroy_window: *const fn (ctx: ?*anyopaque, handle: u64) void,
        set_title: *const fn (ctx: ?*anyopaque, handle: u64, title: []const u8) void,
        set_bounds: *const fn (ctx: ?*anyopaque, handle: u64, bounds: Bounds) void,
        set_visible: *const fn (ctx: ?*anyopaque, handle: u64, visible: bool) void,
        focus: *const fn (ctx: ?*anyopaque, handle: u64) void,
    };

    pub fn createWindow(self: Native, opts: *const CreateOptions) !u64 {
        return self.vtable.create_window(self.ctx, opts);
    }
    pub fn destroyWindow(self: Native, handle: u64) void {
        self.vtable.destroy_window(self.ctx, handle);
    }
    pub fn setTitle(self: Native, handle: u64, title: []const u8) void {
        self.vtable.set_title(self.ctx, handle, title);
    }
    pub fn setBounds(self: Native, handle: u64, bounds: Bounds) void {
        self.vtable.set_bounds(self.ctx, handle, bounds);
    }
    pub fn setVisible(self: Native, handle: u64, visible: bool) void {
        self.vtable.set_visible(self.ctx, handle, visible);
    }
    pub fn focus(self: Native, handle: u64) void {
        self.vtable.focus(self.ctx, handle);
    }
};

pub const Error = error{
    WindowNotFound,
    WindowDestroyed,
    NativeCreateFailed,
    OutOfMemory,
};

pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    native: Native,
    windows: std.AutoHashMap(u32, *Window),
    /// name → id (소유: name_store). fromName lookup에만 사용
    by_name: std.StringHashMap(u32),
    next_id: u32 = 1,

    pub var global: ?*WindowManager = null;

    pub fn init(allocator: std.mem.Allocator, native: Native) WindowManager {
        return .{
            .allocator = allocator,
            .native = native,
            .windows = std.AutoHashMap(u32, *Window).init(allocator),
            .by_name = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *WindowManager) void {
        // 모든 창 destroy + 메모리 회수
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const w = entry.value_ptr.*;
            if (!w.destroyed) self.native.destroyWindow(w.native_handle);
            self.allocator.free(w.title);
            if (w.name) |n| self.allocator.free(n);
            self.allocator.destroy(w);
        }
        self.windows.deinit();
        self.by_name.deinit();
    }

    /// 새 창 생성. name 중복 + forceNew=false면 기존 id 반환.
    pub fn create(self: *WindowManager, opts: CreateOptions) Error!u32 {
        // name 싱글턴 정책
        if (opts.name) |name| {
            if (!opts.force_new) {
                if (self.by_name.get(name)) |existing_id| return existing_id;
            }
        }

        const handle = self.native.createWindow(&opts) catch return Error.NativeCreateFailed;

        const win = self.allocator.create(Window) catch return Error.OutOfMemory;
        errdefer self.allocator.destroy(win);

        const owned_title = self.allocator.dupe(u8, opts.title) catch return Error.OutOfMemory;
        errdefer self.allocator.free(owned_title);

        const owned_name: ?[]const u8 = if (opts.name) |n|
            (self.allocator.dupe(u8, n) catch return Error.OutOfMemory)
        else
            null;
        errdefer if (owned_name) |n| self.allocator.free(n);

        const id = self.next_id;
        self.next_id += 1;

        win.* = .{
            .id = id,
            .native_handle = handle,
            .name = owned_name,
            .title = owned_title,
            .bounds = opts.bounds,
            .parent_id = opts.parent_id,
            .state = .{},
        };

        self.windows.put(id, win) catch return Error.OutOfMemory;
        if (owned_name) |n| {
            self.by_name.put(n, id) catch {}; // 실패해도 창 자체는 생성됨
        }
        return id;
    }

    /// 창 파괴. 이미 destroyed면 WindowDestroyed 반환.
    pub fn destroy(self: *WindowManager, id: u32) Error!void {
        const win = self.windows.get(id) orelse return Error.WindowNotFound;
        if (win.destroyed) return Error.WindowDestroyed;
        self.native.destroyWindow(win.native_handle);
        win.destroyed = true;
        if (win.name) |n| {
            _ = self.by_name.remove(n);
        }
    }

    /// 모든 창 파괴. 프로세스 종료 시 호출.
    pub fn destroyAll(self: *WindowManager) void {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const w = entry.value_ptr.*;
            if (!w.destroyed) {
                self.native.destroyWindow(w.native_handle);
                w.destroyed = true;
            }
        }
        // by_name 비움
        var name_it = self.by_name.iterator();
        while (name_it.next()) |_| {} // nothing, 실제 키는 window 소유이므로 bare remove
        self.by_name.clearRetainingCapacity();
    }

    pub fn get(self: *const WindowManager, id: u32) ?*const Window {
        return self.windows.get(id);
    }

    pub fn fromName(self: *const WindowManager, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    pub fn setTitle(self: *WindowManager, id: u32, title: []const u8) Error!void {
        const win = self.windows.get(id) orelse return Error.WindowNotFound;
        if (win.destroyed) return Error.WindowDestroyed;
        const owned = self.allocator.dupe(u8, title) catch return Error.OutOfMemory;
        self.allocator.free(win.title);
        win.title = owned;
        self.native.setTitle(win.native_handle, title);
    }

    pub fn setBounds(self: *WindowManager, id: u32, bounds: Bounds) Error!void {
        const win = self.windows.get(id) orelse return Error.WindowNotFound;
        if (win.destroyed) return Error.WindowDestroyed;
        win.bounds = bounds;
        self.native.setBounds(win.native_handle, bounds);
    }

    pub fn setVisible(self: *WindowManager, id: u32, visible: bool) Error!void {
        const win = self.windows.get(id) orelse return Error.WindowNotFound;
        if (win.destroyed) return Error.WindowDestroyed;
        win.state.visible = visible;
        self.native.setVisible(win.native_handle, visible);
    }

    pub fn focus(self: *WindowManager, id: u32) Error!void {
        const win = self.windows.get(id) orelse return Error.WindowNotFound;
        if (win.destroyed) return Error.WindowDestroyed;
        self.native.focus(win.native_handle);
    }
};
