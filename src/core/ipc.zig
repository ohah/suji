const std = @import("std");
const wv = @import("webview");
const WebView = @import("webview.zig").WebView;
const loader = @import("loader");
const events = @import("events");

pub const Bridge = struct {
    registry: *loader.BackendRegistry,
    webview: *WebView,
    event_bus: ?*events.EventBus = null,

    pub fn init(webview_ptr: *WebView, registry: *loader.BackendRegistry) Bridge {
        return .{
            .registry = registry,
            .webview = webview_ptr,
        };
    }

    pub fn setEventBus(self: *Bridge, bus: *events.EventBus) void {
        self.event_bus = bus;
    }

    pub fn bind(self: *Bridge) void {
        _ = wv.raw.webview_bind(self.webview.handle.webview, "__suji_invoke__", &invokeCallback, @ptrCast(self));
        _ = wv.raw.webview_bind(self.webview.handle.webview, "__suji_chain__", &chainCallback, @ptrCast(self));
        _ = wv.raw.webview_bind(self.webview.handle.webview, "__suji_fanout__", &fanoutCallback, @ptrCast(self));
        _ = wv.raw.webview_bind(self.webview.handle.webview, "__suji_core__", &coreCallback, @ptrCast(self));
        _ = wv.raw.webview_bind(self.webview.handle.webview, "__suji_emit__", &emitCallback, @ptrCast(self));

        self.webview.init(
            \\window.__suji__ = {
            \\  invoke: function(backend, request) {
            \\    return __suji_invoke__(backend, request);
            \\  },
            \\  chain: function(from, to, request) {
            \\    return __suji_chain__(from, to, request);
            \\  },
            \\  fanout: function(backends, request) {
            \\    return __suji_fanout__(backends, request);
            \\  },
            \\  core: function(request) {
            \\    return __suji_core__(request);
            \\  },
            \\  emit: function(event, data) {
            \\    return __suji_emit__(event, JSON.stringify(data || {}));
            \\  },
            \\  _listeners: {},
            \\  on: function(event, callback) {
            \\    if (!this._listeners[event]) this._listeners[event] = [];
            \\    this._listeners[event].push(callback);
            \\    return function() {
            \\      var idx = window.__suji__._listeners[event].indexOf(callback);
            \\      if (idx >= 0) window.__suji__._listeners[event].splice(idx, 1);
            \\    };
            \\  },
            \\  off: function(event) {
            \\    delete this._listeners[event];
            \\  },
            \\  __dispatch__: function(event, data) {
            \\    var cbs = this._listeners[event] || [];
            \\    for (var i = 0; i < cbs.length; i++) cbs[i](data);
            \\  }
            \\};
        );
    }

    // JS emit → 이벤트 버스
    fn emitCallback(seq: [*c]const u8, req_raw: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const self = getSelf(arg) orelse return;
        const raw = spanC(req_raw);
        const s: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(seq)));

        var bufs: ParseBufs = undefined;
        const parsed = parseJsonStrings(raw, &bufs, 2) catch {
            self.retErr(seq, "parse error");
            return;
        };
        const args = parsed.args();
        if (args.len < 2) { self.retErr(seq, "need event and data"); return; }

        if (self.event_bus) |bus| {
            bus.emit(args[0], args[1]);
        }

        self.ret(s, 0, "{\"ok\":true}");
    }

    fn getSelf(arg: ?*anyopaque) ?*Bridge {
        return @ptrCast(@alignCast(arg orelse return null));
    }

    fn spanC(raw: [*c]const u8) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    }

    fn ret(self: *Bridge, seq: [*c]const u8, status: i32, result: []const u8) void {
        var buf: [16384]u8 = undefined;
        const len = @min(result.len, buf.len - 1);
        @memcpy(buf[0..len], result[0..len]);
        buf[len] = 0;
        _ = wv.raw.webview_return(self.webview.handle.webview, seq, status, &buf);
    }

    fn retErr(self: *Bridge, seq: [*c]const u8, msg: []const u8) void {
        var buf: [512]u8 = undefined;
        const r = std.fmt.bufPrint(&buf, "\"{s}\"", .{msg}) catch "\"error\"";
        buf[r.len] = 0;
        _ = wv.raw.webview_return(self.webview.handle.webview, seq, 1, &buf);
    }

    fn callBackend(self: *Bridge, name: []const u8, request: []const u8) ?[]const u8 {
        // 모든 백엔드 dlopen으로 통일 (Zig 포함)
        var req_buf: [8192]u8 = undefined;
        const len = @min(request.len, req_buf.len - 1);
        @memcpy(req_buf[0..len], request[0..len]);
        req_buf[len] = 0;
        return self.registry.invoke(name, @ptrCast(req_buf[0..len :0]));
    }

    fn freeBackend(self: *Bridge, name: []const u8, response: ?[]const u8) void {
        self.registry.freeResponse(name, response);
    }

    // ============================================
    // 1. Direct: JS → Backend
    // ============================================
    fn invokeCallback(seq: [*c]const u8, req_raw: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const self = getSelf(arg) orelse return;
        const raw = spanC(req_raw);

        var bufs: ParseBufs = undefined;
        const parsed = parseJsonStrings(raw, &bufs, 2) catch {
            self.retErr(seq, "parse error");
            return;
        };
        const args = parsed.args();
        if (args.len < 2) { self.retErr(seq, "need 2 args"); return; }

        var name_buf: [256]u8 = undefined;
        const name = cpBuf(args[0], &name_buf);

        const resp = self.callBackend(name, args[1]);
        if (resp) |r| {
            self.ret(seq, 0, r);
            self.freeBackend(name, resp);
        } else {
            self.retErr(seq, "backend not found");
        }
    }

    // ============================================
    // 2. Chain: Backend A → Zig → Backend B
    // ============================================
    fn chainCallback(seq: [*c]const u8, req_raw: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const self = getSelf(arg) orelse return;
        const raw = spanC(req_raw);

        var bufs: ParseBufs = undefined;
        const parsed = parseJsonStrings(raw, &bufs, 3) catch { self.retErr(seq, "parse error"); return; };
        const args = parsed.args();
        if (args.len < 3) { self.retErr(seq, "need 3 args"); return; }

        var from_buf: [256]u8 = undefined;
        var to_buf: [256]u8 = undefined;
        const from = cpBuf(args[0], &from_buf);
        const to = cpBuf(args[1], &to_buf);

        // Step 1: from 백엔드 호출
        const resp1 = self.callBackend(from, args[2]);
        if (resp1 == null) { self.retErr(seq, "from backend not found"); return; }

        // step1 응답을 복사 (freeBackend 전에)
        var r1_buf: [8192]u8 = undefined;
        const r1 = cpBuf(resp1.?, &r1_buf);
        self.freeBackend(from, resp1);

        // Step 2: to 백엔드에 transform 요청 (단순 텍스트로 전달)
        const resp2 = self.callBackend(to, "{\"cmd\":\"transform\",\"data\":\"chain-relay\"}");
        var r2_buf: [8192]u8 = undefined;
        const r2 = if (resp2) |r| blk: {
            const copied = cpBuf(r, &r2_buf);
            self.freeBackend(to, resp2);
            break :blk copied;
        } else "null";

        var out: [16384]u8 = undefined;
        const result = std.fmt.bufPrint(&out, "{{\"chain\":\"{s}->{s}\",\"step1\":{s},\"step2\":{s}}}", .{ from, to, r1, r2 }) catch {
            self.retErr(seq, "format error");
            return;
        };
        self.ret(seq, 0, result);
    }

    // ============================================
    // 3. Fanout: Zig → All Backends
    // ============================================
    fn fanoutCallback(seq: [*c]const u8, req_raw: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const self = getSelf(arg) orelse return;
        const raw = spanC(req_raw);

        var bufs: ParseBufs = undefined;
        const parsed = parseJsonStrings(raw, &bufs, 2) catch { self.retErr(seq, "parse error"); return; };
        const args = parsed.args();
        if (args.len < 2) { self.retErr(seq, "need 2 args"); return; }

        var backends_buf: [256]u8 = undefined;
        const backends_str = cpBuf(args[0], &backends_buf);

        var out: [16384]u8 = undefined;
        var pos: usize = 0;
        pos += (std.fmt.bufPrint(out[pos..], "{{\"fanout\":[", .{}) catch return).len;

        var iter = std.mem.splitScalar(u8, backends_str, ',');
        var first = true;
        while (iter.next()) |name| {
            const resp = self.callBackend(name, args[1]);
            if (resp) |r| {
                if (!first) pos += (std.fmt.bufPrint(out[pos..], ",", .{}) catch break).len;
                pos += (std.fmt.bufPrint(out[pos..], "{s}", .{r}) catch break).len;
                first = false;
                self.freeBackend(name, resp);
            }
        }
        pos += (std.fmt.bufPrint(out[pos..], "]}}", .{}) catch return).len;
        self.ret(seq, 0, out[0..pos]);
    }

    // ============================================
    // 4. Zig Core Direct
    // ============================================
    fn coreCallback(seq: [*c]const u8, req_raw: [*c]const u8, arg: ?*anyopaque) callconv(.c) void {
        const self = getSelf(arg) orelse return;
        const raw = spanC(req_raw);

        var bufs: ParseBufs = undefined;
        const parsed = parseJsonStrings(raw, &bufs, 1) catch { self.retErr(seq, "parse error"); return; };
        const args = parsed.args();
        if (args.len < 1) { self.retErr(seq, "need 1 arg"); return; }

        const request = args[0];

        if (std.mem.indexOf(u8, request, "core_info") != null) {
            var out: [4096]u8 = undefined;
            var p: usize = 0;
            p += (std.fmt.bufPrint(out[p..], "{{\"from\":\"zig-core\",\"backends\":[", .{}) catch return).len;
            var it = self.registry.backends.iterator();
            var f = true;
            while (it.next()) |entry| {
                if (!f) p += (std.fmt.bufPrint(out[p..], ",", .{}) catch break).len;
                p += (std.fmt.bufPrint(out[p..], "\"{s}\"", .{entry.key_ptr.*}) catch break).len;
                f = false;
            }
            p += (std.fmt.bufPrint(out[p..], "]}}", .{}) catch return).len;
            self.ret(seq, 0, out[0..p]);
        } else if (std.mem.indexOf(u8, request, "core_relay") != null) {
            const target: []const u8 = if (std.mem.indexOf(u8, request, "\"target\":\"rust\"") != null) "rust" else if (std.mem.indexOf(u8, request, "\"target\":\"go\"") != null) "go" else {
                self.retErr(seq, "unknown target");
                return;
            };
            const resp = self.callBackend(target, request);
            if (resp) |r| {
                var out: [16384]u8 = undefined;
                const result = std.fmt.bufPrint(&out, "{{\"from\":\"zig-core\",\"relayed_to\":\"{s}\",\"result\":{s}}}", .{ target, r }) catch {
                    self.freeBackend(target, resp);
                    self.retErr(seq, "format error");
                    return;
                };
                self.ret(seq, 0, result);
                self.freeBackend(target, resp);
            } else {
                self.retErr(seq, "target not found");
            }
        } else {
            self.ret(seq, 0, "{\"from\":\"zig-core\",\"msg\":\"hello from zig\"}");
        }
    }

    // ============================================
    // Helpers
    // ============================================
    fn cpBuf(src: []const u8, dst: []u8) []const u8 {
        const len = @min(src.len, dst.len);
        @memcpy(dst[0..len], src[0..len]);
        return dst[0..len];
    }

    pub const MAX_ARGS = 4;
    pub const ParseBufs = [MAX_ARGS][4096]u8;
    pub const ParseResult = struct {
        slices: [MAX_ARGS][]const u8 = undefined,
        count: usize = 0,

        pub fn args(self: *const ParseResult) []const []const u8 {
            return self.slices[0..self.count];
        }
    };

    pub fn parseJsonStrings(raw: []const u8, bufs: *ParseBufs, max: usize) !ParseResult {
        const State = enum { seek, in_str, esc };
        var state: State = .seek;
        var count: usize = 0;
        var bp: usize = 0;
        const actual = @min(max, MAX_ARGS);
        var result = ParseResult{};

        for (raw) |c| {
            if (count >= actual) break;
            switch (state) {
                .seek => if (c == '"') { state = .in_str; bp = 0; },
                .in_str => {
                    if (c == '\\') { state = .esc; } else if (c == '"') {
                        bufs[count][bp] = 0;
                        result.slices[count] = bufs[count][0..bp];
                        count += 1;
                        state = .seek;
                    } else if (bp < 4095) { bufs[count][bp] = c; bp += 1; }
                },
                .esc => {
                    const u: u8 = switch (c) { 'n' => '\n', 't' => '\t', 'r' => '\r', '"' => '"', '\\' => '\\', '/' => '/', else => c };
                    if (bp < 4095) { bufs[count][bp] = u; bp += 1; }
                    state = .in_str;
                },
            }
        }
        if (count == 0) return error.InvalidArgs;
        result.count = count;
        return result;
    }

    pub fn deinit(self: *Bridge) void { _ = self; }
};
