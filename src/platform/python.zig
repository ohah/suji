const std = @import("std");
const runtime = @import("runtime");
const python_config = @import("python_config");

pub const python_enabled = python_config.python_enabled;

pub const RegisterRouteFn = *const fn (backend_name: []const u8, channel: []const u8) void;

// 코어(BackendRegistry/EventBus) 함수 포인터 — loader.SujiCore 의 해당 필드와 ABI
// 동형(lua.zig 와 동일 타입). outbound invoke/send/on 에 사용.
pub const CoreInvokeFn = *const fn ([*c]const u8, [*c]const u8) callconv(.c) [*c]const u8;
pub const CoreFreeFn = *const fn ([*c]const u8) callconv(.c) void;
pub const CoreEmitFn = *const fn ([*c]const u8, [*c]const u8) callconv(.c) void;
pub const CoreEventCallback = *const fn ([*c]const u8, [*c]const u8, ?*anyopaque) callconv(.c) void;
pub const CoreOnFn = *const fn ([*c]const u8, ?CoreEventCallback, ?*anyopaque) callconv(.c) u64;
pub const CoreOffFn = *const fn (u64) callconv(.c) void;

pub const PythonRuntime = if (python_enabled) EnabledRuntime else DisabledRuntime;

const DisabledRuntime = struct {
    allocator: std.mem.Allocator,
    backend_name: [:0]const u8,
    entry_path: [:0]const u8,
    route_callback: ?RegisterRouteFn = null,
    owns_paths: bool = false,
    initialized: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        backend_name: [:0]const u8,
        entry_path: [:0]const u8,
        route_callback: ?RegisterRouteFn,
        owns_paths: bool,
    ) DisabledRuntime {
        return .{
            .allocator = allocator,
            .backend_name = backend_name,
            .entry_path = entry_path,
            .route_callback = route_callback,
            .owns_paths = owns_paths,
        };
    }

    pub fn start(_: *DisabledRuntime, _: ?[]const u8) !void {
        return error.PythonNotAvailable;
    }

    pub fn invoke(_: *DisabledRuntime, _: []const u8, _: []const u8) ?[*:0]const u8 {
        return null;
    }

    pub fn shutdown(self: *DisabledRuntime) void {
        if (self.owns_paths) {
            if (self.entry_path.len > 0) self.allocator.free(self.entry_path);
            if (self.backend_name.len > 0) self.allocator.free(self.backend_name);
        }
        self.entry_path = "";
        self.backend_name = "";
        self.initialized = false;
    }

    pub fn setCore(_: CoreInvokeFn, _: CoreFreeFn, _: CoreEmitFn, _: CoreOnFn, _: CoreOffFn) void {}

    pub fn invokeC(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
        return null;
    }

    pub fn freeResponseC(_: [*:0]const u8) callconv(.c) void {}
};

const EnabledRuntime = struct {
    const c = @cImport({
        @cDefine("PY_SSIZE_T_CLEAN", {});
        // CPython 3.13 pyatomic.h: zig @cImport 가 __clang__ 을 감지 못해 C11
        // stdatomic 분기(pyatomic_std.h)로 가는데, zig 는 stdatomic 의 _Generic
        // 매크로(atomic_fetch_add 등)를 translate 하지 못한다. GCC __atomic builtin
        // 경로(pyatomic_gcc.h, _Generic 없음)를 강제해 회피.
        @cDefine("_Py_USE_GCC_BUILTIN_ATOMICS", "1");
        @cInclude("Python.h");
    });

    // suji.on 리스너 — EventBus C 콜백 arg 로 이 포인터를 받아 어느 Python 콜러블을
    // 부를지 식별(lua LuaListener 대응, registry ref 대신 PyObject* strong ref).
    const PyListener = struct {
        rt: *EnabledRuntime,
        callback: *c.PyObject,
        id: u64 = 0,
    };

    allocator: std.mem.Allocator,
    backend_name: [:0]const u8,
    entry_path: [:0]const u8,
    route_callback: ?RegisterRouteFn = null,
    owns_paths: bool = false,
    // Python 은 프로세스 전역 인터프리터 — 별도 핸들 불필요. PyEval_SaveThread 토큰만 보관.
    main_thread_state: ?*c.PyThreadState = null,
    handlers: std.StringHashMap(*c.PyObject),
    event_listeners: std.ArrayList(*PyListener) = .empty,
    initialized: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        backend_name: [:0]const u8,
        entry_path: [:0]const u8,
        route_callback: ?RegisterRouteFn,
        owns_paths: bool,
    ) EnabledRuntime {
        return .{
            .allocator = allocator,
            .backend_name = backend_name,
            .entry_path = entry_path,
            .route_callback = route_callback,
            .owns_paths = owns_paths,
            .handlers = std.StringHashMap(*c.PyObject).init(allocator),
        };
    }

    pub fn setCore(invoke_fn: CoreInvokeFn, free_fn: CoreFreeFn, emit_fn: CoreEmitFn, on_fn: CoreOnFn, off_fn: CoreOffFn) void {
        g_core_invoke = invoke_fn;
        g_core_free = free_fn;
        g_core_emit = emit_fn;
        g_core_on = on_fn;
        g_core_off = off_fn;
    }

    // home_override: packaged 시 exe-dir 의 번들 stdlib PYTHONHOME(호출자 소유,
    // start 동안만 유효). null 이면 python_config.python_home(dev staging) 사용.
    pub fn start(self: *EnabledRuntime, home_override: ?[]const u8) !void {
        if (self.initialized) return;

        // suji 모듈을 인터프리터 init 전에 inittab 에 추가 — main.py 의 `import suji` 가
        // 보이게(lua installSujiModule 이 newstate 직후인 것과 대응).
        if (c.PyImport_AppendInittab("suji", &pyInitSujiModule) != 0) return error.PythonInittabFailed;

        // Isolated config — site/env/argv 무시(임베드 표준, 3.12+).
        var config: c.PyConfig = undefined;
        c.PyConfig_InitIsolatedConfig(&config);
        defer c.PyConfig_Clear(&config);

        // PYTHONHOME — packaged 면 home_override(exe-dir 번들 stdlib), 아니면
        // python_config.python_home(dev staging). Python 은 여기 아래 lib/pythonX.Y
        // 에서 stdlib(json 등)를 로드하므로 둘 중 유효 경로가 반드시 있어야 한다.
        const home_slice: []const u8 = home_override orelse python_config.python_home;
        if (home_slice.len > 0) {
            const home_z = self.allocator.dupeZ(u8, home_slice) catch return error.OutOfMemory;
            defer self.allocator.free(home_z);
            const st = c.PyConfig_SetBytesString(&config, &config.home, home_z.ptr);
            if (c.PyStatus_Exception(st) != 0) return error.PythonHomeFailed;
        }

        const status = c.Py_InitializeFromConfig(&config);
        if (c.PyStatus_Exception(status) != 0) return error.PythonInitFailed;

        // main.py top-level 의 suji.handle/on 이 이 런타임을 찾도록(lua 와 동일).
        active_registration_runtime = self;
        defer active_registration_runtime = null;
        g_python_runtime = self;

        if (!self.runMainFile()) {
            return error.PythonScriptRunFailed;
        }

        // 메인 스레드 GIL 해제 — 이후 다른 스레드(EventBus emit, invoke 워커)가
        // PyGILState_Ensure 로 진입 가능. GIL 이 lua mutex+depth 역할을 대체한다.
        self.main_thread_state = c.PyEval_SaveThread();

        self.initialized = true;
        std.debug.print("[suji-python] started: {s}\n", .{self.entry_path});
    }

    // PyRun_SimpleFile 류는 매크로일 수 있어 함수형 ...ExFlags 를 직접 호출
    // (lua 가 luaL_loadfilex 를 직접 부른 것과 동형). closeit=1 이 fclose.
    fn runMainFile(self: *EnabledRuntime) bool {
        const fp = c.fopen(self.entry_path.ptr, "rb") orelse return false;
        const rc = c.PyRun_SimpleFileExFlags(fp, self.entry_path.ptr, 1, null);
        if (rc != 0) {
            if (c.PyErr_Occurred() != null) c.PyErr_Print();
            return false;
        }
        return true;
    }

    fn pyInitSujiModule() callconv(.c) ?*c.PyObject {
        // PyModuleDef_HEAD_INIT 매크로는 translate-c 가 못 풀어 zeroes 로 0 초기화 후
        // 필요한 필드만 채운다(m_base 는 CPython 이 첫 사용 시 보정).
        suji_module_def.m_name = "suji";
        suji_module_def.m_size = -1;
        suji_module_def.m_methods = &suji_methods;
        return c.PyModule_Create(&suji_module_def);
    }

    // suji.handle(channel, fn) — 인바운드 핸들러 등록(lua handleRegistration 대응).
    // 인자 추출 헬퍼 — variadic PyArg_ParseTuple 은 zig C variadic 전달에서 깨지므로
    // (포인터가 어긋나 segfault) non-variadic PyTuple_GetItem + PyUnicode_AsUTF8 사용.
    // PyTuple_GetItem(IndexError)/PyUnicode_AsUTF8(TypeError) 는 실패 시 예외를 set 한다.
    // 호출자는 null 을 받으면 `orelse return pyNone()` 으로 유효 객체를 반환하는데, 예외가
    // set 된 채 non-NULL 을 돌려주면 CPython 이 SystemError("result with exception set")를
    // 던진다 — null 반환 전 예외를 정리해 호출자의 graceful 반환을 안전하게 한다.
    fn tupleStr(args: ?*c.PyObject, idx: c.Py_ssize_t) ?[*:0]const u8 {
        const args_c: [*c]c.PyObject = @ptrCast(args);
        if (c.PyTuple_Size(args_c) <= idx) {
            c.PyErr_Clear();
            return null;
        }
        const item = c.PyTuple_GetItem(args_c, idx);
        if (item == null) {
            c.PyErr_Clear();
            return null;
        }
        const s = c.PyUnicode_AsUTF8(item);
        if (s == null) {
            c.PyErr_Clear();
            return null;
        }
        return @ptrCast(s);
    }

    fn tupleObj(args: ?*c.PyObject, idx: c.Py_ssize_t) ?*c.PyObject {
        const args_c: [*c]c.PyObject = @ptrCast(args);
        if (c.PyTuple_Size(args_c) <= idx) {
            c.PyErr_Clear();
            return null;
        }
        const item = c.PyTuple_GetItem(args_c, idx);
        if (item == null) {
            c.PyErr_Clear();
            return null;
        }
        return @ptrCast(item);
    }

    fn pyHandle(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
        const self = active_registration_runtime orelse g_python_runtime orelse return pyNone();
        const ch_z = tupleStr(args, 0) orelse return pyNone();
        const callable = tupleObj(args, 1) orelse return pyNone();
        if (c.PyCallable_Check(callable) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "suji.handle: handler must be callable");
            return null;
        }
        const channel = std.mem.span(ch_z);
        c.Py_IncRef(callable);
        if (self.handlers.getPtr(channel)) |old| {
            c.Py_DecRef(old.*);
            old.* = callable;
        } else {
            const owned = self.allocator.dupe(u8, channel) catch {
                c.Py_DecRef(callable);
                return pyNone();
            };
            self.handlers.put(owned, callable) catch {
                self.allocator.free(owned);
                c.Py_DecRef(callable);
                return pyNone();
            };
        }
        if (self.route_callback) |cb| cb(self.backend_name, channel);
        return pyNone();
    }

    // suji.invoke(target, request_json) -> response_json — outbound cross-call.
    fn pyInvoke(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
        const invoke_fn = g_core_invoke orelse return pyStr("{\"error\":\"core not connected\"}");
        const target = tupleStr(args, 0) orelse return pyStr("{\"error\":\"invoke: target must be a string\"}");
        const req = tupleStr(args, 1) orelse return pyStr("{\"error\":\"invoke: request must be a string\"}");
        const resp = invoke_fn(@ptrCast(target), @ptrCast(req));
        if (resp != null) {
            const span = std.mem.span(@as([*:0]const u8, @ptrCast(resp)));
            const out = c.PyUnicode_FromStringAndSize(@ptrCast(span.ptr), @intCast(span.len));
            if (g_core_free) |ff| ff(resp);
            // 응답이 유효 UTF-8 이 아니면 out==NULL+예외 set — 다른 에러 경로와 동일하게
            // 에러 JSON 으로 폴백(무음 실패/SystemError 방지).
            if (out == null) {
                c.PyErr_Clear();
                return pyStr("{\"error\":\"invoke: response is not valid UTF-8\"}");
            }
            return out;
        }
        return pyStr("{}");
    }

    // suji.send(channel, data) — 이벤트 발신.
    fn pySend(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
        const emit_fn = g_core_emit orelse return pyNone();
        const ch = tupleStr(args, 0) orelse return pyNone();
        const data = tupleStr(args, 1) orelse return pyNone();
        emit_fn(@ptrCast(ch), @ptrCast(data));
        return pyNone();
    }

    // suji.on(channel, fn) -> listener_id — 이벤트 수신.
    fn pyOn(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
        const self = active_registration_runtime orelse g_python_runtime orelse return pyNone();
        const on_fn = g_core_on orelse return pyNone();
        const ch_z = tupleStr(args, 0) orelse return pyNone();
        const callable = tupleObj(args, 1) orelse return pyNone();
        if (c.PyCallable_Check(callable) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "suji.on: callback must be callable");
            return null;
        }
        c.Py_IncRef(callable);
        const listener = self.allocator.create(PyListener) catch {
            c.Py_DecRef(callable);
            return pyNone();
        };
        listener.* = .{ .rt = self, .callback = callable };
        self.event_listeners.append(self.allocator, listener) catch {
            c.Py_DecRef(callable);
            self.allocator.destroy(listener);
            return pyNone();
        };
        listener.id = on_fn(@ptrCast(ch_z), pyEventCallback, listener);
        if (listener.id == 0) {
            // 코어 등록 실패(id==0) — listener 를 보관하면 누수 + shutdown 시 off(0) 호출.
            // 방금 append 한 항목을 롤백한다.
            _ = self.event_listeners.pop();
            c.Py_DecRef(callable);
            self.allocator.destroy(listener);
            return c.PyLong_FromUnsignedLongLong(0);
        }
        return c.PyLong_FromUnsignedLongLong(listener.id);
    }

    pub fn invoke(self: *EnabledRuntime, channel: []const u8, data: []const u8) ?[*:0]const u8 {
        if (!self.initialized) return null;
        const handler = self.handlers.get(channel) orelse return null;

        // GIL 획득 — 멀티스레드 직렬화 + 같은 스레드 재진입(cross-call/이벤트)을 모두
        // 처리(lua 의 mutex+ReentrantGuard 대체).
        const gil = c.PyGILState_Ensure();
        defer c.PyGILState_Release(gil);

        const arg = c.PyUnicode_FromStringAndSize(@ptrCast(data.ptr), @intCast(data.len)) orelse {
            if (c.PyErr_Occurred() != null) c.PyErr_Print();
            return self.dupeResponse("{\"error\":\"python arg encode failed\"}");
        };
        defer c.Py_DecRef(arg);
        // 단일 인자 호출은 vectorcall 경로(non-variadic) — variadic PyObject_CallFunction
        // 은 zig C variadic 전달에서 깨지므로 사용 금지(tupleStr 주석 참조).
        const result = c.PyObject_CallOneArg(handler, arg) orelse {
            if (c.PyErr_Occurred() != null) c.PyErr_Print();
            return self.dupeResponse("{\"error\":\"python handler failed\"}");
        };
        defer c.Py_DecRef(result);

        var out_len: c.Py_ssize_t = 0;
        const out_ptr = c.PyUnicode_AsUTF8AndSize(result, &out_len) orelse {
            if (c.PyErr_Occurred() != null) c.PyErr_Print();
            return self.dupeResponse("{\"error\":\"python handler returned non-string\"}");
        };
        // AsUTF8 버퍼는 result 소유 → DECREF(defer) 전에 dupeZ.
        const out = self.allocator.dupeZ(u8, out_ptr[0..@intCast(out_len)]) catch return null;
        return out.ptr;
    }

    fn dupeResponse(self: *EnabledRuntime, body: []const u8) ?[*:0]const u8 {
        const out = self.allocator.dupeZ(u8, body) catch return null;
        return out.ptr;
    }

    // EventBus 가 emit 한 스레드에서 호출. arg=*PyListener.
    fn pyEventCallback(_: [*c]const u8, data: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const listener: *PyListener = @ptrCast(@alignCast(arg orelse return));
        const d = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
        listener.rt.dispatchEvent(listener.callback, d);
    }

    fn dispatchEvent(self: *EnabledRuntime, callback: *c.PyObject, data: []const u8) void {
        if (!self.initialized) return;
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

    pub fn shutdown(self: *EnabledRuntime) void {
        // 리스너 off 먼저 — events.zig off-quiescence 가 in-flight emit 콜백 종료를
        // 보장하므로 이후 DECREF 가 안전(lua shutdown 과 동일 근거).
        for (self.event_listeners.items) |listener| {
            if (g_core_off) |off| off(listener.id);
        }
        if (self.main_thread_state) |ts| {
            // Python 정리는 GIL 필요 — 메인 스레드 GIL 재획득 후 Finalize.
            c.PyEval_RestoreThread(ts);
            self.main_thread_state = null;
            for (self.event_listeners.items) |listener| {
                c.Py_DecRef(listener.callback);
                self.allocator.destroy(listener);
            }
            var it = self.handlers.iterator();
            while (it.next()) |entry| {
                c.Py_DecRef(entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.handlers.deinit();
            _ = c.Py_FinalizeEx();
        } else {
            for (self.event_listeners.items) |listener| self.allocator.destroy(listener);
            var it = self.handlers.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.handlers.deinit();
        }
        self.event_listeners.deinit(self.allocator);

        if (g_python_runtime == self) g_python_runtime = null;
        if (active_registration_runtime == self) active_registration_runtime = null;
        if (self.owns_paths) {
            if (self.entry_path.len > 0) self.allocator.free(self.entry_path);
            if (self.backend_name.len > 0) self.allocator.free(self.backend_name);
        }
        self.entry_path = "";
        self.backend_name = "";
        self.initialized = false;
    }

    pub fn invokeC(channel: [*:0]const u8, data: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
        const rt = g_python_runtime orelse return null;
        return rt.invoke(std.mem.span(channel), std.mem.span(data));
    }

    pub fn freeResponseC(ptr: [*:0]const u8) callconv(.c) void {
        const rt = g_python_runtime orelse return;
        const body = std.mem.span(ptr);
        const mutable: [*:0]u8 = @constCast(ptr);
        rt.allocator.free(mutable[0..body.len :0]);
    }

    fn pyNone() ?*c.PyObject {
        const none: *c.PyObject = @ptrCast(&c._Py_NoneStruct);
        c.Py_IncRef(none);
        return none;
    }

    fn pyStr(s: [:0]const u8) ?*c.PyObject {
        return c.PyUnicode_FromStringAndSize(@ptrCast(s.ptr), @intCast(s.len));
    }

    var suji_methods = [_]c.PyMethodDef{
        .{ .ml_name = "handle", .ml_meth = pyHandle, .ml_flags = c.METH_VARARGS, .ml_doc = null },
        .{ .ml_name = "invoke", .ml_meth = pyInvoke, .ml_flags = c.METH_VARARGS, .ml_doc = null },
        .{ .ml_name = "send", .ml_meth = pySend, .ml_flags = c.METH_VARARGS, .ml_doc = null },
        .{ .ml_name = "on", .ml_meth = pyOn, .ml_flags = c.METH_VARARGS, .ml_doc = null },
        .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
    };
    var suji_module_def: c.PyModuleDef = std.mem.zeroes(c.PyModuleDef);
};

var g_python_runtime: ?*PythonRuntime = null;
var active_registration_runtime: ?*PythonRuntime = null;

var g_core_invoke: ?CoreInvokeFn = null;
var g_core_free: ?CoreFreeFn = null;
var g_core_emit: ?CoreEmitFn = null;
var g_core_on: ?CoreOnFn = null;
var g_core_off: ?CoreOffFn = null;

test "PythonRuntime executes example handler when enabled" {
    if (!python_enabled) return error.SkipZigTest;

    runtime.io = std.testing.io;
    runtime.gpa = std.testing.allocator;

    // name/entry 는 init(owns_paths=true) 이 소유 → shutdown(항상 실행되는 defer)이
    // 해제한다. 여기서 추가 errdefer/defer free 를 두면 에러 경로에서 double-free.
    const name = try std.testing.allocator.dupeZ(u8, "python");
    const entry = try std.testing.allocator.dupeZ(u8, "examples/python-backend/backends/python/main.py");

    // Py init/finalize 는 프로세스당 1회가 안전 — test 는 단일 start/invoke/shutdown.
    var rt = PythonRuntime.init(std.testing.allocator, name, entry, null, true);
    defer rt.shutdown();
    try rt.start(null);

    // json.dumps 기본 separators 는 ", "/": " (공백 포함) — 실제 Python 출력 형태로 단언.
    const ping = rt.invoke("ping", "{\"cmd\":\"ping\"}") orelse return error.NoPythonResponse;
    defer PythonRuntime.freeResponseC(ping);
    const ping_body = std.mem.span(ping);
    try std.testing.expect(std.mem.indexOf(u8, ping_body, "\"runtime\": \"python\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ping_body, "\"msg\": \"pong\"") != null);

    // echo — json round-trip(파싱→직렬화) 검증.
    const echo = rt.invoke("echo", "{\"cmd\":\"echo\",\"value\":\"hello\"}") orelse return error.NoPythonResponse;
    defer PythonRuntime.freeResponseC(echo);
    const echo_body = std.mem.span(echo);
    try std.testing.expect(std.mem.indexOf(u8, echo_body, "\"runtime\": \"python\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, echo_body, "\"value\": \"hello\"") != null);
}
