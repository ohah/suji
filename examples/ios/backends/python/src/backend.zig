//! iOS/Android 정적 링크 embedded CPython 3.13 백엔드 (suji_python_backend_*).
//!
//! 데스크탑 `src/platform/python.zig` 의 모바일 대응판. 데스크탑은 BackendRegistry
//! +CEF 호스트로 임베드하지만, 모바일은 정적 링크 모델이라(sqlite 백엔드가 데스크탑
//! plugins/sqlite 와 동형인 것과 동일 방식) 코어/SDK/CEF 비의존으로 재구성한다.
//! 단일 바이너리 심볼 충돌을 피하려 고유 네임스페이스 `suji_python_backend_*`.
//!
//! 차이(다른 모바일 백엔드는 init=no-op): Python `start` 가 Py_Initialize + main.py
//! 실행(핸들러 등록), `handle_ipc` 가 cmd 추출 → GIL → Python 핸들러 디스패치.
//! outbound `suji.invoke/send/on` 은 같은 앱에 정적 링크된 suji_core C ABI(extern)로
//! 직접 배선. 핸들러 이름은 main.py 가 `suji.handle` 로 등록 → 호스트(Swift)가
//! `suji_python_backend_channels` 로 목록을 받아 각 채널을 `suji_core_register_handler`
//! 로 등록 → 프론트가 `suji.invoke("ping")` 처럼 데스크탑과 동일하게 호출(채널=핸들러).
//!
//! 데스크탑 교훈 그대로: variadic PyArg_ParseTuple/CallFunction 은 zig C variadic
//! 전달에서 깨지므로 non-variadic(PyTuple_GetItem/AsUTF8/CallOneArg) 사용,
//! pyatomic.h 는 `_Py_USE_GCC_BUILTIN_ATOMICS` 로 GCC builtin 분기 강제.

const std = @import("std");

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cDefine("_Py_USE_GCC_BUILTIN_ATOMICS", "1");
    @cInclude("Python.h");
});

const alloc = std.heap.c_allocator;

// 같은 앱에 정적 링크된 suji_core C ABI (include/suji_core.h) — outbound 전용.
// 데스크탑 setCore(함수 포인터 주입) 대신 모바일은 링크 심볼을 직접 호출.
extern fn suji_core_invoke(channel: [*:0]const u8, json: [*:0]const u8) ?[*:0]const u8;
extern fn suji_core_free(ptr: ?[*:0]const u8) void;
extern fn suji_core_emit(event_name: [*:0]const u8, json: [*:0]const u8) void;
const CoreEventCb = *const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void;
extern fn suji_core_on(event_name: [*:0]const u8, callback: ?CoreEventCb, arg: ?*anyopaque) u64;
extern fn suji_core_off(listener_id: u64) void;

// suji.on 리스너 — EventBus C 콜백 arg 로 받아 어느 Python 콜러블을 부를지 식별.
const PyListener = struct {
    callback: *c.PyObject,
    id: u64 = 0,
};

// 모바일은 단일 전역 인터프리터(데스크탑도 Py_Initialize 가 프로세스당 1회). sqlite
// 백엔드의 전역 Registry 패턴 동형 — self 대신 전역 rt.
const Runtime = struct {
    handlers: std.StringHashMap(*c.PyObject) = std.StringHashMap(*c.PyObject).init(alloc),
    event_listeners: std.ArrayList(*PyListener) = .empty,
    main_thread_state: ?*c.PyThreadState = null,
    initialized: bool = false,
};
var rt: Runtime = .{};

// ============================================
// suji 모듈 (handle/invoke/send/on) — 데스크탑 python.zig 와 동일 의미
// ============================================

// variadic 회피 인자 추출(데스크탑 tupleStr/tupleObj 와 동일).
fn tupleStr(args: ?*c.PyObject, idx: c.Py_ssize_t) ?[*:0]const u8 {
    const args_c: [*c]c.PyObject = @ptrCast(args);
    if (c.PyTuple_Size(args_c) <= idx) return null;
    const item = c.PyTuple_GetItem(args_c, idx);
    if (item == null) return null;
    const s = c.PyUnicode_AsUTF8(item);
    if (s == null) return null;
    return @ptrCast(s);
}

fn tupleObj(args: ?*c.PyObject, idx: c.Py_ssize_t) ?*c.PyObject {
    const args_c: [*c]c.PyObject = @ptrCast(args);
    if (c.PyTuple_Size(args_c) <= idx) return null;
    const item = c.PyTuple_GetItem(args_c, idx);
    if (item == null) return null;
    return @ptrCast(item);
}

fn pyNone() ?*c.PyObject {
    const none: *c.PyObject = @ptrCast(&c._Py_NoneStruct);
    c.Py_IncRef(none);
    return none;
}

fn pyStr(s: [:0]const u8) ?*c.PyObject {
    return c.PyUnicode_FromStringAndSize(@ptrCast(s.ptr), @intCast(s.len));
}

fn pyHandle(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const ch_z = tupleStr(args, 0) orelse return pyNone();
    const callable = tupleObj(args, 1) orelse return pyNone();
    if (c.PyCallable_Check(callable) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "suji.handle: handler must be callable");
        return null;
    }
    const channel = std.mem.span(ch_z);
    c.Py_IncRef(callable);
    if (rt.handlers.getPtr(channel)) |old| {
        c.Py_DecRef(old.*);
        old.* = callable;
    } else {
        const owned = alloc.dupe(u8, channel) catch {
            c.Py_DecRef(callable);
            return pyNone();
        };
        rt.handlers.put(owned, callable) catch {
            alloc.free(owned);
            c.Py_DecRef(callable);
            return pyNone();
        };
    }
    return pyNone();
}

fn pyInvoke(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const target = tupleStr(args, 0) orelse return pyStr("{\"error\":\"invoke: target must be a string\"}");
    const req = tupleStr(args, 1) orelse return pyStr("{\"error\":\"invoke: request must be a string\"}");
    const resp = suji_core_invoke(@ptrCast(target), @ptrCast(req));
    if (resp) |r| {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(r)));
        const out = c.PyUnicode_FromStringAndSize(@ptrCast(span.ptr), @intCast(span.len));
        suji_core_free(r);
        return out;
    }
    return pyStr("{}");
}

fn pySend(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const ch = tupleStr(args, 0) orelse return pyNone();
    const data = tupleStr(args, 1) orelse return pyNone();
    suji_core_emit(@ptrCast(ch), @ptrCast(data));
    return pyNone();
}

fn pyOn(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const ch_z = tupleStr(args, 0) orelse return pyNone();
    const callable = tupleObj(args, 1) orelse return pyNone();
    if (c.PyCallable_Check(callable) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "suji.on: callback must be callable");
        return null;
    }
    c.Py_IncRef(callable);
    const listener = alloc.create(PyListener) catch {
        c.Py_DecRef(callable);
        return pyNone();
    };
    listener.* = .{ .callback = callable };
    rt.event_listeners.append(alloc, listener) catch {
        c.Py_DecRef(callable);
        alloc.destroy(listener);
        return pyNone();
    };
    listener.id = suji_core_on(@ptrCast(ch_z), pyEventCallback, listener);
    return c.PyLong_FromUnsignedLongLong(listener.id);
}

// EventBus 가 emit 한 스레드에서 호출. arg=*PyListener.
fn pyEventCallback(_: [*c]const u8, data: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
    const listener: *PyListener = @ptrCast(@alignCast(arg orelse return));
    const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
    dispatchEvent(listener.callback, d);
}

fn dispatchEvent(callback: *c.PyObject, data: []const u8) void {
    if (!rt.initialized) return;
    const gil = c.PyGILState_Ensure();
    defer c.PyGILState_Release(gil);
    const arg = c.PyUnicode_FromStringAndSize(@ptrCast(data.ptr), @intCast(data.len)) orelse {
        if (c.PyErr_Occurred() != null) c.PyErr_Print();
        return;
    };
    defer c.Py_DecRef(arg);
    const r = c.PyObject_CallOneArg(callback, arg);
    if (r) |rp| {
        c.Py_DecRef(rp);
    } else if (c.PyErr_Occurred() != null) {
        c.PyErr_Print();
    }
}

var suji_methods = [_]c.PyMethodDef{
    .{ .ml_name = "handle", .ml_meth = pyHandle, .ml_flags = c.METH_VARARGS, .ml_doc = null },
    .{ .ml_name = "invoke", .ml_meth = pyInvoke, .ml_flags = c.METH_VARARGS, .ml_doc = null },
    .{ .ml_name = "send", .ml_meth = pySend, .ml_flags = c.METH_VARARGS, .ml_doc = null },
    .{ .ml_name = "on", .ml_meth = pyOn, .ml_flags = c.METH_VARARGS, .ml_doc = null },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};
var suji_module_def: c.PyModuleDef = std.mem.zeroes(c.PyModuleDef);

fn pyInitSujiModule() callconv(.c) ?*c.PyObject {
    suji_module_def.m_name = "suji";
    suji_module_def.m_size = -1;
    suji_module_def.m_methods = &suji_methods;
    return c.PyModule_Create(&suji_module_def);
}

// ============================================
// 인터프리터 부팅 / 핸들러 디스패치
// ============================================

// PYTHONHOME(home)/main.py(entry)는 호스트가 앱 번들 경로로 전달. testbed
// iOSTestbed 참조: IsolatedConfig + config.home + write_bytecode=0(번들 read-only).
fn startRuntime(home: [*:0]const u8, entry: [*:0]const u8) bool {
    if (rt.initialized) return true;

    // iOS: 컬러/버퍼 출력 비활성(testbed 동형 — 샌드박스 stdout 안정).
    _ = c.setenv("NO_COLOR", "1", 1);
    _ = c.setenv("PYTHON_COLORS", "0", 1);

    if (c.PyImport_AppendInittab("suji", &pyInitSujiModule) != 0) return false;

    var config: c.PyConfig = undefined;
    c.PyConfig_InitIsolatedConfig(&config);
    defer c.PyConfig_Clear(&config);
    config.write_bytecode = 0; // 번들은 read-only → .pyc 쓰기 시도 회피.

    const st = c.PyConfig_SetBytesString(&config, &config.home, home);
    if (c.PyStatus_Exception(st) != 0) return false;

    const status = c.Py_InitializeFromConfig(&config);
    if (c.PyStatus_Exception(status) != 0) return false;

    const fp = c.fopen(entry, "rb") orelse return false;
    const rc = c.PyRun_SimpleFileExFlags(fp, entry, 1, null); // closeit=1 → fclose
    if (rc != 0) {
        if (c.PyErr_Occurred() != null) c.PyErr_Print();
        return false;
    }

    // 메인 스레드 GIL 해제 → 이후 handle_ipc/이벤트가 PyGILState_Ensure 로 진입.
    rt.main_thread_state = c.PyEval_SaveThread();
    rt.initialized = true;
    return true;
}

// 경량 `"key":"<value>"` 추출(zig 형제 백엔드 field() 동형) — 전체 JSON DOM 파싱
// 없이 cmd 한 필드만. 요청은 호스트 브리지가 만든 compact JSON({"cmd":"..",..}).
fn field(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const i = std.mem.indexOf(u8, json, pat) orelse return null;
    const start = i + pat.len;
    const rel = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
    return json[start .. start + rel];
}

fn dupZ(s: []const u8) [*:0]u8 {
    const b = alloc.allocSentinel(u8, s.len, 0) catch return @constCast("{}");
    @memcpy(b, s);
    return b.ptr;
}

// 핸들러 호출(데스크탑 invoke 와 동일 — GIL + CallOneArg). 반환은 c_allocator
// 버퍼(호스트가 suji_python_backend_free 로 반납).
fn invokeHandler(channel: []const u8, data: []const u8) ?[*:0]u8 {
    if (!rt.initialized) return null;
    const handler = rt.handlers.get(channel) orelse return null;

    const gil = c.PyGILState_Ensure();
    defer c.PyGILState_Release(gil);

    const arg = c.PyUnicode_FromStringAndSize(@ptrCast(data.ptr), @intCast(data.len)) orelse {
        if (c.PyErr_Occurred() != null) c.PyErr_Print();
        return dupZ("{\"error\":\"python arg encode failed\"}");
    };
    defer c.Py_DecRef(arg);
    const result = c.PyObject_CallOneArg(handler, arg) orelse {
        if (c.PyErr_Occurred() != null) c.PyErr_Print();
        return dupZ("{\"error\":\"python handler failed\"}");
    };
    defer c.Py_DecRef(result);

    var out_len: c.Py_ssize_t = 0;
    const out_ptr = c.PyUnicode_AsUTF8AndSize(result, &out_len) orelse {
        if (c.PyErr_Occurred() != null) c.PyErr_Print();
        return dupZ("{\"error\":\"python handler returned non-string\"}");
    };
    return dupZ(out_ptr[0..@intCast(out_len)]);
}

// ============================================
// C ABI (모바일 정적 링크 — 고유 심볼 suji_python_backend_*)
// ============================================

export fn suji_python_backend_init(core: ?*const anyopaque) callconv(.c) void {
    _ = core; // outbound 는 extern suji_core_* 직접 사용 — core 인자 불요(sqlite 동형).
}

// 호스트가 앱 번들의 PYTHONHOME(stdlib 상위)과 main.py 절대경로로 1회 호출.
export fn suji_python_backend_start(home: [*:0]const u8, entry: [*:0]const u8) callconv(.c) c_int {
    return if (startRuntime(home, entry)) 0 else -1;
}

// start 후 등록된 핸들러 이름 JSON 배열(호스트가 각 채널을 suji_core_register_handler).
// 핸들러 이름은 suji.handle 인자(개발자 식별자)라 단순 직렬화로 충분.
export fn suji_python_backend_channels() callconv(.c) ?[*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var out = std.ArrayList(u8).empty;
    out.append(a, '[') catch return dupZ("[]");
    var it = rt.handlers.keyIterator();
    var first = true;
    while (it.next()) |k| {
        if (!first) out.append(a, ',') catch return dupZ("[]");
        first = false;
        out.append(a, '"') catch return dupZ("[]");
        out.appendSlice(a, k.*) catch return dupZ("[]");
        out.append(a, '"') catch return dupZ("[]");
    }
    out.append(a, ']') catch return dupZ("[]");
    return dupZ(out.items);
}

export fn suji_python_backend_handle_ipc(req: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const r = std.mem.span(req);
    // cmd 만 경량 추출(핸들러가 전체 요청을 json.loads 로 재파싱하므로 여기서 DOM
    // 파싱 불요 — 데스크탑과 동일하게 핸들러는 `{"cmd":..,..}` 전체를 받는다).
    const cmd = field(r, "cmd") orelse return dupZ("{\"error\":\"missing cmd\"}");
    return invokeHandler(cmd, r) orelse dupZ("{\"error\":\"unknown handler\"}");
}

export fn suji_python_backend_free(p: ?[*:0]u8) callconv(.c) void {
    if (p) |ptr| {
        const s = std.mem.span(ptr);
        if (s.len == 0 or std.mem.eql(u8, s, "{}")) return; // static fallback
        alloc.free(s);
    }
}

export fn suji_python_backend_destroy() callconv(.c) void {
    for (rt.event_listeners.items) |listener| suji_core_off(listener.id);
    if (rt.main_thread_state) |ts| {
        c.PyEval_RestoreThread(ts); // 정리는 GIL 필요.
        rt.main_thread_state = null;
        for (rt.event_listeners.items) |listener| {
            c.Py_DecRef(listener.callback);
            alloc.destroy(listener);
        }
        var it = rt.handlers.iterator();
        while (it.next()) |entry| {
            c.Py_DecRef(entry.value_ptr.*);
            alloc.free(entry.key_ptr.*);
        }
        rt.handlers.deinit();
        _ = c.Py_FinalizeEx();
    } else {
        for (rt.event_listeners.items) |listener| alloc.destroy(listener);
        var it = rt.handlers.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        rt.handlers.deinit();
    }
    rt.event_listeners.deinit(alloc);
    rt.initialized = false;
}
