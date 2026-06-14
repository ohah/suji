//! session.setPermissionRequestHandler — CEF `cef_permission_handler_t`.
//!
//! Electron `session.setPermissionRequestHandler(handler)` 대응. 렌더러(웹 콘텐츠)가
//! geolocation/notifications/clipboard/midi-sysex/idle-detection/window-management 등
//! 권한을 요청하면 CEF `on_show_permission_prompt` 가 **UI 스레드**에서 호출된다.
//! app 이 핸들러를 등록한 경우(`permissionSetHandlerEnabled(true)`), CEF 콜백을
//! `prompt_id`(CEF 부여 고유 id) 키로 hold 하고 `session:permission-request` 이벤트
//! ({permissionId, origin, permissions:[...]})를 EventBus 로 발신 + 1(async) 반환 →
//! app(프론트/백엔드)이 결정을 내려 `session_permission_response {permissionId, granted}`
//! cmd 로 응답하면 hold 한 콜백의 `cont(ACCEPT|DENY)` 를 호출(webRequest.onBeforeRequest
//! deferred-callback 패턴 동형).
//!
//! 미등록 시 `on_show_permission_prompt` 가 0 반환 → CEF 기본 처리(Alloy style=IGNORE
//! → promise 미해결, Chrome style=권한 UI). app 등록 전에는 비파괴.
//!
//! `on_dismiss_permission_prompt`: CEF 가 우리 prompt 를 외부 이유(navigation/browser
//! close)로 종료 → hold 한 콜백을 **cont 없이 release**(close-during-defer UAF/double-
//! resolve 방지. deferred-response criticals 선례).
//!
//! cont 는 UI 스레드 컨텍스트가 안전 — 프론트 invoke(UI 스레드)는 직접 cont, 백엔드
//! 워커 스레드는 UI 로 task post(cef_session_proxy SetProxyTask 동형).
//!
//! getUserMedia(camera/mic)는 별도 콜백 `on_request_media_access_permission` 경로 —
//! 같은 cef_permission_handler_t 에 슬롯 추가(별도 handler 불필요). prompt 와 callback
//! 타입(cef_media_access_callback_t)·cont 인자(allowed bitmask)가 달라 media pending pool +
//! `session:media-access-request {mediaRequestId,origin,audio,video}` 이벤트 +
//! `mediaAccessRespond(id,audio,video)` 로 분리. 정직 경계: ① camera/mic 실 grant 는 실
//! 카메라+권한 다이얼로그라 헤드리스 e2e 불가(빌드+wire 가드가 천장) ② media 는 prompt 의
//! on_dismiss 같은 외부-종료 알림이 CEF 에 없어 navigation/close 중 미응답 callback 정리가
//! prompt 보다 약함(앱이 respond 보장 필요).

const std = @import("std");
const util = @import("util");
const cef = @import("cef.zig");

const c = cef.c;
const zeroCefStruct = cef.zeroCefStruct;
const initBaseRefCounted = cef.initBaseRefCounted;
const cefStringToUtf8 = cef.cefStringToUtf8;

const c_allocator = std.heap.c_allocator;

// ---- EventBus emit 핸들러(main 이 주입; webRequest 동형) ----
pub const PermissionEmitFn = *const fn (channel: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void;
var g_emit_fn: ?PermissionEmitFn = null;

pub fn setPermissionEmitHandler(fn_ptr: PermissionEmitFn) void {
    g_emit_fn = fn_ptr;
}

// app 이 setPermissionRequestHandler 를 등록했는지. false 면 on_show 가 0 반환(CEF 기본).
var g_have_handler: std.atomic.Value(bool) = .init(false);

/// Electron `session.setPermissionRequestHandler(handler|null)` 의 등록/해제.
pub fn permissionSetHandlerEnabled(enabled: bool) void {
    g_have_handler.store(enabled, .release);
}

// ---- pending prompt callbacks (prompt_id keyed; webRequest pending pool 동형) ----
const MAX_PENDING: usize = 64;

const Pending = struct {
    id: u64,
    callback: *c.cef_permission_prompt_callback_t,
};

var g_pending: [MAX_PENDING]Pending = undefined;
var g_pending_count: usize = 0;
var g_lock: std.atomic.Value(bool) = .init(false);

fn pendingLock() void {
    while (g_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}
fn pendingUnlock() void {
    g_lock.store(false, .release);
}

/// callback 을 pending pool 에 저장. caller 가 add_ref 보장. 가득 차면 false.
fn pendingPush(id: u64, callback: *c.cef_permission_prompt_callback_t) bool {
    pendingLock();
    defer pendingUnlock();
    if (g_pending_count >= MAX_PENDING) return false;
    g_pending[g_pending_count] = .{ .id = id, .callback = callback };
    g_pending_count += 1;
    return true;
}

/// id 로 callback 추출(consume). 없으면 null. respond 와 dismiss 가 경쟁해도 한쪽만 획득.
fn pendingTake(id: u64) ?*c.cef_permission_prompt_callback_t {
    pendingLock();
    defer pendingUnlock();
    var i: usize = 0;
    while (i < g_pending_count) : (i += 1) {
        if (g_pending[i].id == id) {
            const cb = g_pending[i].callback;
            g_pending[i] = g_pending[g_pending_count - 1];
            g_pending_count -= 1;
            return cb;
        }
    }
    return null;
}

// ---- pending media-access callbacks (getUserMedia camera/mic) ----
// on_request_media_access_permission 은 prompt_id 가 없으므로 자체 media id 부여.
// g_lock 공유(prompt/media 직렬화 — 둘 다 UI 스레드 콜백 + 임의 스레드 respond).
const PendingMedia = struct {
    id: u64,
    callback: *c.cef_media_access_callback_t,
    // 요청된 permission mask — cont(allowed) 시 allowed ⊆ requested 클램프용(CEF 계약:
    // "allowed_permissions must match required_permissions"). SDK 도 보장하지만 core 방어.
    requested: u32,
};

var g_pending_media: [MAX_PENDING]PendingMedia = undefined;
var g_pending_media_count: usize = 0;
var g_next_media_id: std.atomic.Value(u64) = .init(1);

fn nextMediaId() u64 {
    return g_next_media_id.fetchAdd(1, .acq_rel);
}

fn pendingPushMedia(id: u64, callback: *c.cef_media_access_callback_t, requested: u32) bool {
    pendingLock();
    defer pendingUnlock();
    if (g_pending_media_count >= MAX_PENDING) return false;
    g_pending_media[g_pending_media_count] = .{ .id = id, .callback = callback, .requested = requested };
    g_pending_media_count += 1;
    return true;
}

fn pendingTakeMedia(id: u64) ?PendingMedia {
    pendingLock();
    defer pendingUnlock();
    var i: usize = 0;
    while (i < g_pending_media_count) : (i += 1) {
        if (g_pending_media[i].id == id) {
            const pm = g_pending_media[i];
            g_pending_media[i] = g_pending_media[g_pending_media_count - 1];
            g_pending_media_count -= 1;
            return pm;
        }
    }
    return null;
}

// ---- permission bitmask → 이름 JSON 배열 ----
const PermBit = struct { mask: c_uint, name: []const u8 };

// on_show_permission_prompt 가 덮는 권한군(non-API-gated 상수만 — 빌드 안정성).
const perm_table = [_]PermBit{
    .{ .mask = c.CEF_PERMISSION_TYPE_AR_SESSION, .name = "ar" },
    .{ .mask = c.CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, .name = "cameraPanTiltZoom" },
    .{ .mask = c.CEF_PERMISSION_TYPE_CAMERA_STREAM, .name = "camera" },
    .{ .mask = c.CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, .name = "capturedSurfaceControl" },
    .{ .mask = c.CEF_PERMISSION_TYPE_CLIPBOARD, .name = "clipboard" },
    .{ .mask = c.CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, .name = "topLevelStorageAccess" },
    .{ .mask = c.CEF_PERMISSION_TYPE_DISK_QUOTA, .name = "diskQuota" },
    .{ .mask = c.CEF_PERMISSION_TYPE_LOCAL_FONTS, .name = "localFonts" },
    .{ .mask = c.CEF_PERMISSION_TYPE_GEOLOCATION, .name = "geolocation" },
    .{ .mask = c.CEF_PERMISSION_TYPE_HAND_TRACKING, .name = "handTracking" },
    .{ .mask = c.CEF_PERMISSION_TYPE_IDENTITY_PROVIDER, .name = "identityProvider" },
    .{ .mask = c.CEF_PERMISSION_TYPE_IDLE_DETECTION, .name = "idleDetection" },
    .{ .mask = c.CEF_PERMISSION_TYPE_MIC_STREAM, .name = "microphone" },
    .{ .mask = c.CEF_PERMISSION_TYPE_MIDI_SYSEX, .name = "midiSysex" },
    .{ .mask = c.CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, .name = "multipleDownloads" },
    .{ .mask = c.CEF_PERMISSION_TYPE_NOTIFICATIONS, .name = "notifications" },
    .{ .mask = c.CEF_PERMISSION_TYPE_KEYBOARD_LOCK, .name = "keyboardLock" },
    .{ .mask = c.CEF_PERMISSION_TYPE_POINTER_LOCK, .name = "pointerLock" },
    .{ .mask = c.CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, .name = "protectedMediaIdentifier" },
    .{ .mask = c.CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, .name = "registerProtocolHandler" },
    .{ .mask = c.CEF_PERMISSION_TYPE_STORAGE_ACCESS, .name = "storageAccess" },
    .{ .mask = c.CEF_PERMISSION_TYPE_VR_SESSION, .name = "vr" },
    .{ .mask = c.CEF_PERMISSION_TYPE_WEB_APP_INSTALLATION, .name = "webAppInstallation" },
    .{ .mask = c.CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, .name = "windowManagement" },
    .{ .mask = c.CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, .name = "fileSystem" },
};

/// bitmask → `["geolocation","notifications"]` 형태 JSON 배열을 buf 에 작성, 길이 반환.
fn buildPermsArray(mask: c_uint, buf: []u8) usize {
    var n: usize = 0;
    buf[n] = '[';
    n += 1;
    var first = true;
    inline for (perm_table) |p| {
        if (mask & p.mask != 0) {
            if (!first) {
                buf[n] = ',';
                n += 1;
            }
            first = false;
            buf[n] = '"';
            n += 1;
            @memcpy(buf[n..][0..p.name.len], p.name);
            n += p.name.len;
            buf[n] = '"';
            n += 1;
        }
    }
    buf[n] = ']';
    n += 1;
    return n;
}

fn emitRequest(prompt_id: u64, origin: []const u8, mask: c_uint) void {
    const emit = g_emit_fn orelse return;
    var perms_buf: [768]u8 = undefined;
    const perms_n = buildPermsArray(mask, &perms_buf);
    var origin_esc: [1024]u8 = undefined;
    const oe = util.escapeJsonStrFull(origin, &origin_esc) orelse return;
    var payload_buf: [2048]u8 = undefined;
    const payload = std.fmt.bufPrintZ(
        &payload_buf,
        "{{\"permissionId\":{d},\"origin\":\"{s}\",\"permissions\":{s}}}",
        .{ prompt_id, origin_esc[0..oe], perms_buf[0..perms_n] },
    ) catch return;
    emit("session:permission-request", payload.ptr);
}

fn emitMediaRequest(media_id: u64, origin: []const u8, mask: u32) void {
    const emit = g_emit_fn orelse return;
    const audio = (mask & c.CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0;
    const video = (mask & c.CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0;
    var origin_esc: [1024]u8 = undefined;
    const oe = util.escapeJsonStrFull(origin, &origin_esc) orelse return;
    var payload_buf: [1536]u8 = undefined;
    const payload = std.fmt.bufPrintZ(
        &payload_buf,
        "{{\"mediaRequestId\":{d},\"origin\":\"{s}\",\"audio\":{},\"video\":{}}}",
        .{ media_id, origin_esc[0..oe], audio, video },
    ) catch return;
    emit("session:media-access-request", payload.ptr);
}

// ---- CEF cef_permission_handler_t 싱글톤(cef_request_handler 동형) ----
var g_handler: c.cef_permission_handler_t = undefined;
var g_handler_initialized: bool = false;

fn ensureHandler() void {
    if (g_handler_initialized) return;
    zeroCefStruct(c.cef_permission_handler_t, &g_handler);
    initBaseRefCounted(&g_handler.base);
    g_handler.on_show_permission_prompt = &onShowPermissionPrompt;
    g_handler.on_dismiss_permission_prompt = &onDismissPermissionPrompt;
    g_handler.on_request_media_access_permission = &onRequestMediaAccess;
    g_handler_initialized = true;
}

pub fn getPermissionHandler(_: ?*c._cef_client_t) callconv(.c) ?*c._cef_permission_handler_t {
    ensureHandler();
    return &g_handler;
}

fn onShowPermissionPrompt(
    _: ?*c._cef_permission_handler_t,
    _: ?*c._cef_browser_t,
    prompt_id: u64,
    requesting_origin: [*c]const c.cef_string_t,
    requested_permissions: c_uint,
    callback: ?*c._cef_permission_prompt_callback_t,
) callconv(.c) c_int {
    if (!g_have_handler.load(.acquire)) return 0; // 미등록 → CEF 기본 처리
    const cb = callback orelse return 0;
    if (cb.base.add_ref) |add_ref| _ = add_ref(&cb.base);
    if (!pendingPush(prompt_id, cb)) {
        // pool 가득 — 우리 ref 해제 + 기본 처리로 fallback(buffer overflow 방지).
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return 0;
    }
    var origin_buf: [1024]u8 = undefined;
    const origin = if (requesting_origin != null) cefStringToUtf8(requesting_origin, &origin_buf) else "";
    emitRequest(prompt_id, origin, requested_permissions);
    return 1; // async — app 응답까지 hold
}

/// getUserMedia(camera/mic) 권한 요청 — CEF `on_request_media_access_permission`(UI 스레드).
/// prompt 경로(on_show_permission_prompt)와 별개 콜백·callback 타입(cef_media_access_callback_t).
/// 자체 media id 부여 → `session:media-access-request {mediaRequestId,origin,audio,video}` 발신
/// + 1(async) → app 이 `session_media_access_response {mediaRequestId,audio,video}` 로 응답하면
/// cont(allowed bitmask). 미등록(g_have_handler=false) 시 0 반환 → CEF 기본(Alloy=deny).
/// 정직 경계: media 는 prompt 의 on_dismiss 같은 외부-종료 알림이 CEF 에 없어, navigation/
/// close 중 미응답 callback 은 hold 채로 남는다(앱이 respond 보장 필요 — prompt 보다 약한 정리).
fn onRequestMediaAccess(
    _: ?*c._cef_permission_handler_t,
    _: ?*c._cef_browser_t,
    _: ?*c._cef_frame_t,
    requesting_origin: [*c]const c.cef_string_t,
    requested_permissions: u32,
    callback: ?*c._cef_media_access_callback_t,
) callconv(.c) c_int {
    if (!g_have_handler.load(.acquire)) return 0; // 미등록 → CEF 기본 처리(deny)
    const cb = callback orelse return 0;
    if (cb.base.add_ref) |add_ref| _ = add_ref(&cb.base);
    const id = nextMediaId();
    if (!pendingPushMedia(id, cb, requested_permissions)) {
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return 0; // pool 가득 → 기본 처리 fallback
    }
    var origin_buf: [1024]u8 = undefined;
    const origin = if (requesting_origin != null) cefStringToUtf8(requesting_origin, &origin_buf) else "";
    emitMediaRequest(id, origin, requested_permissions);
    return 1; // async — app 응답까지 hold
}

fn onDismissPermissionPrompt(
    _: ?*c._cef_permission_handler_t,
    _: ?*c._cef_browser_t,
    prompt_id: u64,
    _: c.cef_permission_request_result_t,
) callconv(.c) void {
    // CEF 가 우리 prompt 를 외부 이유(navigation/close)로 종료 — 아직 hold 중이면 cont 없이
    // release(CEF 가 이미 내부 정리. 여기서 cont 시 double-resolve/UAF).
    if (pendingTake(prompt_id)) |cb| {
        if (cb.base.release) |rel| _ = rel(&cb.base);
    }
    if (g_emit_fn) |emit| {
        var buf: [96]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "{{\"permissionId\":{d}}}", .{prompt_id}) catch return;
        emit("session:permission-dismissed", p.ptr);
    }
}

fn contAndRelease(cb: *c.cef_permission_prompt_callback_t, result: c.cef_permission_request_result_t) void {
    if (cb.cont) |fp| fp(cb, result);
    if (cb.base.release) |rel| _ = rel(&cb.base);
}

// ---- off-UI-thread(백엔드 워커) → UI 스레드 post task(cef_session_proxy 동형) ----
const RespondTask = struct {
    task: c.cef_task_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    callback: *c.cef_permission_prompt_callback_t,
    result: c.cef_permission_request_result_t,
};

fn taskFromBase(base: ?*c.cef_base_ref_counted_t) ?*RespondTask {
    return @ptrCast(@alignCast(base orelse return null));
}
fn taskFromSelf(self: ?*c._cef_task_t) ?*RespondTask {
    return @ptrCast(@alignCast(self orelse return null));
}
fn taskAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const t = taskFromBase(base) orelse return;
    _ = t.ref_count.fetchAdd(1, .acq_rel);
}
fn taskRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = taskFromBase(base) orelse return 0;
    if (t.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    t.allocator.destroy(t);
    return 1;
}
fn taskHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = taskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) == 1) 1 else 0;
}
fn taskHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = taskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) >= 1) 1 else 0;
}
fn taskExecute(self: ?*c._cef_task_t) callconv(.c) void {
    const t = taskFromSelf(self) orelse return;
    contAndRelease(t.callback, t.result);
}

/// Electron 핸들러의 결정 적용. prompt_id 로 hold 콜백을 찾아 cont(ACCEPT|DENY).
/// 없는 id(이미 resolve/dismiss) → false. UI 스레드면 즉시 cont, 백엔드 워커면 UI 로 post.
pub fn permissionRespond(prompt_id: u64, granted: bool) bool {
    const cb = pendingTake(prompt_id) orelse return false;
    const result: c.cef_permission_request_result_t =
        if (granted) c.CEF_PERMISSION_RESULT_ACCEPT else c.CEF_PERMISSION_RESULT_DENY;

    if (c.cef_currently_on(c.TID_UI) == 1) {
        contAndRelease(cb, result);
        return true;
    }

    // 백엔드 워커 스레드 — UI 로 post. 실패(OOM/shutdown) 시 우리 ref 만 해제(cont 생략 —
    // off-UI cont 는 미보장; shutdown 경로라 prompt 무의미). honest: respond 실패=false.
    const t = c_allocator.create(RespondTask) catch {
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return false;
    };
    t.* = .{ .allocator = c_allocator, .callback = cb, .result = result };
    @memset(std.mem.asBytes(&t.task), 0);
    t.task.base.size = @sizeOf(c.cef_task_t);
    t.task.base.add_ref = &taskAddRef;
    t.task.base.release = &taskRelease;
    t.task.base.has_one_ref = &taskHasOneRef;
    t.task.base.has_at_least_one_ref = &taskHasAtLeastOneRef;
    t.task.execute = &taskExecute;
    if (c.cef_post_task(c.TID_UI, &t.task) != 1) {
        _ = taskRelease(&t.task.base); // task 메모리 free(callback 미접근)
        if (cb.base.release) |rel| _ = rel(&cb.base); // 우리 ref 해제(cont 없이)
        return false;
    }
    return true; // posted — UI 스레드에서 곧 cont
}

// ---- media-access cont(allowed bitmask) — prompt 와 callback 타입/cont 인자가 달라 별도 ----
fn contMediaAndRelease(cb: *c.cef_media_access_callback_t, allowed: u32) void {
    if (cb.cont) |fp| fp(cb, allowed);
    if (cb.base.release) |rel| _ = rel(&cb.base);
}

const MediaRespondTask = struct {
    task: c.cef_task_t = undefined,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    callback: *c.cef_media_access_callback_t,
    allowed: u32,
};

fn mediaTaskFromBase(base: ?*c.cef_base_ref_counted_t) ?*MediaRespondTask {
    return @ptrCast(@alignCast(base orelse return null));
}
fn mediaTaskFromSelf(self: ?*c._cef_task_t) ?*MediaRespondTask {
    return @ptrCast(@alignCast(self orelse return null));
}
fn mediaTaskAddRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) void {
    const t = mediaTaskFromBase(base) orelse return;
    _ = t.ref_count.fetchAdd(1, .acq_rel);
}
fn mediaTaskRelease(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = mediaTaskFromBase(base) orelse return 0;
    if (t.ref_count.fetchSub(1, .acq_rel) != 1) return 0;
    t.allocator.destroy(t);
    return 1;
}
fn mediaTaskHasOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = mediaTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) == 1) 1 else 0;
}
fn mediaTaskHasAtLeastOneRef(base: ?*c.cef_base_ref_counted_t) callconv(.c) i32 {
    const t = mediaTaskFromBase(base) orelse return 0;
    return if (t.ref_count.load(.acquire) >= 1) 1 else 0;
}
fn mediaTaskExecute(self: ?*c._cef_task_t) callconv(.c) void {
    const t = mediaTaskFromSelf(self) orelse return;
    contMediaAndRelease(t.callback, t.allowed);
}

/// Electron media-access 결정 적용. mediaRequestId 로 hold callback 을 찾아 cont(allowed
/// bitmask). audio/video 각각 grant. 없는 id(이미 resolve) → false. UI 스레드면 즉시 cont,
/// 백엔드 워커면 UI 로 post(permissionRespond 동형).
pub fn mediaAccessRespond(media_id: u64, audio_allowed: bool, video_allowed: bool) bool {
    const pm = pendingTakeMedia(media_id) orelse return false;
    const cb = pm.callback;
    var allowed: u32 = 0;
    if (audio_allowed) allowed |= c.CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
    if (video_allowed) allowed |= c.CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    allowed &= pm.requested; // CEF 계약: allowed ⊆ requested (요청 안 된 타입 grant 방지)

    if (c.cef_currently_on(c.TID_UI) == 1) {
        contMediaAndRelease(cb, allowed);
        return true;
    }

    const t = c_allocator.create(MediaRespondTask) catch {
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return false;
    };
    t.* = .{ .allocator = c_allocator, .callback = cb, .allowed = allowed };
    @memset(std.mem.asBytes(&t.task), 0);
    t.task.base.size = @sizeOf(c.cef_task_t);
    t.task.base.add_ref = &mediaTaskAddRef;
    t.task.base.release = &mediaTaskRelease;
    t.task.base.has_one_ref = &mediaTaskHasOneRef;
    t.task.base.has_at_least_one_ref = &mediaTaskHasAtLeastOneRef;
    t.task.execute = &mediaTaskExecute;
    if (c.cef_post_task(c.TID_UI, &t.task) != 1) {
        _ = mediaTaskRelease(&t.task.base);
        if (cb.base.release) |rel| _ = rel(&cb.base);
        return false;
    }
    return true;
}

// 검증: 이 모듈은 cef.zig(@cImport CEF) 의존이라 standalone unit-test 모듈이 될 수 없다
// (cef_web_request/cef_session_proxy 동일 제약). 따라서 ① tests/cef_ipc_test.zig 의
// source-contract 가드(파일·cmd·핸들러 와이어 substring) + ② 실 e2e(geolocation 권한
// grant/deny 왕복, tests/e2e/system-integration.test.ts)로 검증한다. buildPermsArray /
// pending pool / cont 경로는 e2e 의 실 onShow→emit→respond→cont 왕복이 커버.
