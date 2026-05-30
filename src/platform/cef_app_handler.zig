const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const cef_command_line_policy = @import("cef_command_line_policy.zig");
const cef_render_handler = @import("cef_render_handler.zig");
const cef_scheme = @import("cef_scheme.zig");
const cef = @import("cef.zig");

const c = cef.c;

const cef_command_line_platform: cef_command_line_policy.Platform = switch (builtin.os.tag) {
    .macos => .macos,
    .linux => .linux,
    .windows => .windows,
    else => .other,
};

pub fn initApp(app: *c.cef_app_t) void {
    cef.zeroCefStruct(c.cef_app_t, app);
    cef.initBaseRefCounted(&app.base);
    app.get_render_process_handler = &cef_render_handler.getRenderProcessHandler;
    app.on_before_command_line_processing = &onBeforeCommandLineProcessing;
    app.on_register_custom_schemes = &cef_scheme.onRegisterCustomSchemes;
    cef_render_handler.initRenderHandler();
}

/// CEF 커맨드라인 플래그 주입 (키체인 팝업 방지 등)
fn onBeforeCommandLineProcessing(
    _: ?*c._cef_app_t,
    _: [*c]const c.cef_string_t,
    command_line: ?*c._cef_command_line_t,
) callconv(.c) void {
    const cmd = command_line orelse return;

    const ci_env = runtime.env("SUJI_CEF_CI") orelse runtime.env("CI");
    const switches = cef_command_line_policy.switches(cef_command_line_platform, ci_env);
    for (switches.slice()) |sw| {
        if (sw.value) |value| {
            appendCefSwitchWithValue(cmd, sw.name, value);
        } else {
            appendCefSwitch(cmd, sw.name);
        }
    }

    // CEF 디버그 모드 — Chromium verbose 로깅(stderr)으로 렌더러 crash/IPC 추적.
    if (cefDebug()) {
        appendCefSwitchWithValue(cmd, "enable-logging", "stderr");
        appendCefSwitchWithValue(cmd, "v", "1");
    }
}

fn appendCefSwitch(cmd: *c._cef_command_line_t, name: []const u8) void {
    var key: c.cef_string_t = .{};
    cef.setCefString(&key, name);
    cmd.append_switch.?(cmd, &key);
}

fn appendCefSwitchWithValue(cmd: *c._cef_command_line_t, name: []const u8, value: []const u8) void {
    var key: c.cef_string_t = .{};
    var val: c.cef_string_t = .{};
    cef.setCefString(&key, name);
    cef.setCefString(&val, value);
    cmd.append_switch_with_value.?(cmd, &key, &val);
}

/// CEF 디버그 모드 — `SUJI_CEF_DEBUG` 환경변수가 있으면 on. 서브프로세스(렌더러/
/// GPU/network)도 부모 env 를 상속하므로 동일하게 동작. on 일 때 Chromium verbose
/// 로깅 + 렌더러 crash/navigation 진단 핸들러 + DIAG 마커 + 패닉 stderr 직출력.
/// 데스크톱 CEF 멀티프로세스 IPC/crash 디버깅용(issue #60). 기본 off = 프로덕션 클린.
var g_cef_debug_cached: ?bool = null;
pub fn cefDebug() bool {
    if (g_cef_debug_cached) |v| return v;
    const v = runtime.env("SUJI_CEF_DEBUG") != null;
    g_cef_debug_cached = v;
    return v;
}

/// CEF 디버그 모드 — CEF 구조체 레이아웃/상수 덤프(@sizeOf/@offsetOf/API_VERSION).
/// Debug vs Release 의 translate-c ABI 일치 확인용(이슈 #60 진단에서 동형 검증).
pub fn diagPrintCefAbi() void {
    std.debug.print(
        "[cef-abi] API_VER={d} base={d} app={d} rph={d} v8ctx={d} msg={d} browser={d} oncreate_off={d} onmsg_off={d} setting={d}\n",
        .{
            c.CEF_API_VERSION,
            @sizeOf(c.cef_base_ref_counted_t),
            @sizeOf(c.cef_app_t),
            @sizeOf(c.cef_render_process_handler_t),
            @sizeOf(c.cef_v8_context_t),
            @sizeOf(c.cef_process_message_t),
            @sizeOf(c.cef_browser_t),
            @offsetOf(c.cef_render_process_handler_t, "on_context_created"),
            @offsetOf(c.cef_render_process_handler_t, "on_process_message_received"),
            @sizeOf(c.cef_settings_t),
        },
    );
}
