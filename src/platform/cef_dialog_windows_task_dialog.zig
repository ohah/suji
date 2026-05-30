//! Windows TaskDialogIndirect backend for custom message dialog buttons.

const std = @import("std");
const builtin = @import("builtin");
const dialog_types = @import("cef_dialog_types.zig");
const messagebox = @import("cef_dialog_windows_messagebox.zig");

const MessageBoxOpts = dialog_types.MessageBoxOpts;
const MessageBoxResult = dialog_types.MessageBoxResult;

pub fn messageBox(opts: MessageBoxOpts) MessageBoxResult {
    if (comptime builtin.os.tag != .windows) return .{};
    return task_dialog.messageBox(opts);
}

const task_dialog = if (builtin.os.tag == .windows) struct {
    // ============================================
    // TaskDialogIndirect — 임의 button text 지원 (macOS NSAlert 패리티).
    // TASKDIALOGCONFIG 와 TASKDIALOG_BUTTON 둘 다 pshpack1.h pack(1) 라
    // Zig extern struct natural align 으로는 표현 불가 → raw byte buffer 로
    // 수동 layout. x64 전용 (suji 데스크톱은 모두 x64).
    //
    // ⚠️ 정적 import 하지 않음 — comctl32.dll 이 SxS manifest 없이 로드되면
    // legacy v5.82 가 resolve 되고 TaskDialogIndirect symbol 이 없어 프로세스
    // 로드 자체가 STATUS_ENTRYPOINT_NOT_FOUND 로 실패한다. runtime LoadLibrary +
    // GetProcAddress 로 graceful detect → 없으면 MessageBoxW fallback.
    // ============================================
    const HMODULE = ?*anyopaque;
    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

    const TaskDialogIndirectFn = *const fn (
        pTaskConfig: *const anyopaque,
        pnButton: ?*i32,
        pnRadioButton: ?*i32,
        pfVerificationFlagChecked: ?*i32,
    ) callconv(.winapi) i32;

    var g_task_dialog_ptr: ?TaskDialogIndirectFn = null;
    var g_task_dialog_resolved: std.atomic.Value(bool) = .init(false);
    var g_task_dialog_resolve_lock: std.atomic.Value(bool) = .init(false);

    fn resolveTaskDialog() ?TaskDialogIndirectFn {
        if (g_task_dialog_resolved.load(.acquire)) return g_task_dialog_ptr;
        // double-checked locking via simple spinlock — 첫 해상도만 진입.
        while (g_task_dialog_resolve_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer g_task_dialog_resolve_lock.store(false, .release);
        if (g_task_dialog_resolved.load(.acquire)) return g_task_dialog_ptr;
        const dll = std.unicode.utf8ToUtf16LeStringLiteral("comctl32.dll");
        if (LoadLibraryW(dll.ptr)) |mod| {
            if (GetProcAddress(mod, "TaskDialogIndirect")) |ptr| {
                g_task_dialog_ptr = @ptrCast(@alignCast(ptr));
            }
        }
        g_task_dialog_resolved.store(true, .release);
        return g_task_dialog_ptr;
    }

    const TDC_SIZE: usize = 160; // pack(1) x64 size
    const TDB_SIZE: usize = 12; // pack(1) x64 size
    // MAKEINTRESOURCEW(-N) = (LPWSTR)((ULONG_PTR)((WORD)(-N))) — 16비트 unsigned
    // 캐스트만 → high word 0. Zig 에서 isize 로 -N 쓰면 sign-extend 되어 Windows
    // 가 valid PCWSTR pointer 로 해석 → garbage deref. (WORD)(-N) 동등으로 mask.
    const TD_INFORMATION_ICON: usize = @as(u16, @bitCast(@as(i16, -3)));
    const TD_WARNING_ICON: usize = @as(u16, @bitCast(@as(i16, -1)));
    const TD_ERROR_ICON: usize = @as(u16, @bitCast(@as(i16, -2)));
    const TDF_ALLOW_DIALOG_CANCELLATION: u32 = 0x0008;

    fn writeUsizeLE(buf: []u8, val: usize) void {
        std.mem.writeInt(usize, buf[0..@sizeOf(usize)], val, .little);
    }
    fn writeU32LE(buf: []u8, val: u32) void {
        std.mem.writeInt(u32, buf[0..4], val, .little);
    }
    fn writeI32LE(buf: []u8, val: i32) void {
        std.mem.writeInt(i32, buf[0..4], val, .little);
    }
    fn writeIsizeLE(buf: []u8, val: isize) void {
        std.mem.writeInt(isize, buf[0..@sizeOf(isize)], val, .little);
    }

    const MAX_TD_BUTTONS: usize = 8;
    const TD_LABEL_WIDE_MAX: usize = 64;

    fn messageBox(opts: MessageBoxOpts) MessageBoxResult {
        // 라벨 → UTF-16 변환 (각 버튼당 최대 64자).
        var label_storage: [MAX_TD_BUTTONS][TD_LABEL_WIDE_MAX]u16 = undefined;
        var button_records: [MAX_TD_BUTTONS * TDB_SIZE]u8 = undefined;
        const button_count = @min(opts.buttons.len, MAX_TD_BUTTONS);
        var i: usize = 0;
        while (i < button_count) : (i += 1) {
            const label_z = messagebox.utf8ToZ16(&label_storage[i], opts.buttons[i]) orelse return .{};
            const off = i * TDB_SIZE;
            // TASKDIALOG_BUTTON: int nButtonID(4), PCWSTR pszButtonText(8) — pack(1)
            writeI32LE(button_records[off .. off + 4], @intCast(100 + @as(i32, @intCast(i))));
            writeUsizeLE(button_records[off + 4 .. off + 12], @intFromPtr(label_z.ptr));
        }

        // Title (window) / instruction (main) / content (sub) UTF-16.
        var title_buf: [256]u16 = undefined;
        var instruction_buf: [1024]u16 = undefined;
        var content_buf: [4096]u16 = undefined;
        const title_z: ?[*:0]const u16 = if (opts.title.len > 0)
            (messagebox.utf8ToZ16(&title_buf, opts.title) orelse return .{}).ptr
        else
            null;
        const instruction_z: ?[*:0]const u16 = if (opts.message.len > 0)
            (messagebox.utf8ToZ16(&instruction_buf, opts.message) orelse return .{}).ptr
        else
            null;
        const content_z: ?[*:0]const u16 = if (opts.detail.len > 0)
            (messagebox.utf8ToZ16(&content_buf, opts.detail) orelse return .{}).ptr
        else
            null;

        const icon_literal: isize = switch (opts.style) {
            .info => TD_INFORMATION_ICON,
            .err => TD_ERROR_ICON,
            .warning => TD_WARNING_ICON,
            .question => TD_INFORMATION_ICON, // task dialog 에 question 없음
            .none => 0,
        };

        // TASKDIALOGCONFIG 빌드 (pack(1), x64 = 160 bytes).
        var tdc: [TDC_SIZE]u8 = std.mem.zeroes([TDC_SIZE]u8);
        writeU32LE(tdc[0..4], TDC_SIZE); // cbSize
        // 4..12 hwndParent = null
        // 12..20 hInstance = null
        writeU32LE(tdc[20..24], TDF_ALLOW_DIALOG_CANCELLATION); // dwFlags
        // 24..28 dwCommonButtons = 0 (custom buttons만)
        writeUsizeLE(tdc[28..36], @intFromPtr(title_z)); // pszWindowTitle
        // 36..44 hMainIcon union — pszMainIcon literal (negative LONG_PTR)
        writeIsizeLE(tdc[36..44], icon_literal);
        writeUsizeLE(tdc[44..52], @intFromPtr(instruction_z)); // pszMainInstruction
        writeUsizeLE(tdc[52..60], @intFromPtr(content_z)); // pszContent
        writeU32LE(tdc[60..64], @intCast(button_count)); // cButtons
        writeUsizeLE(tdc[64..72], if (button_count > 0) @intFromPtr(&button_records) else 0); // pButtons
        writeI32LE(tdc[72..76], 100); // nDefaultButton (first custom)
        // 76..80 cRadioButtons = 0
        // 80..88 pRadioButtons = null
        // 88..92 nDefaultRadioButton = 0
        // 92..156 — all zero (no expand/footer/etc.)
        // 156..160 cxWidth = 0 (auto)

        const task_dialog_fn = resolveTaskDialog() orelse return messagebox.messageBoxFallback(opts);
        var clicked_id: i32 = 0;
        const hr = task_dialog_fn(&tdc, &clicked_id, null, null);
        if (hr != 0) {
            // 매니페스트 누락/E_NOTIMPL/HRESULT 실패 → MessageBoxW fallback (always available).
            return messagebox.messageBoxFallback(opts);
        }
        const idx_signed = clicked_id - 100;
        // ESC/IDCANCEL/dialog 외부 닫기 → custom button 범위 밖 → 마지막 버튼 인덱스 매핑.
        // MessageBoxW path 의 IDCANCEL → "Cancel" 버튼 (보통 마지막) 매핑과 동일 컨벤션.
        const idx: usize = if (idx_signed >= 0 and idx_signed < @as(i32, @intCast(button_count)))
            @intCast(idx_signed)
        else if (button_count > 0)
            button_count - 1
        else
            0;
        return .{ .response = idx, .checkbox_checked = opts.checkbox_checked };
    }
} else struct {};
