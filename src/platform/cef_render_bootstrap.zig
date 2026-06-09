//! Renderer-side `window.__suji__` JavaScript bootstrap.

const builtin = @import("builtin");
const cef = @import("cef.zig");

const c = cef.c;
const setCefString = cef.setCefString;

/// JS 헬퍼 코드 주입 — 기존 webview ipc.zig와 동일한 window.__suji__ API
pub fn injectJsHelpers(ctx: *c._cef_v8_context_t) void {
    // __suji_raw_invoke__(json) → Promise<string>  (네이티브 V8 바인딩)
    // __suji_raw_emit__(event, data) → void         (네이티브 V8 바인딩)
    // 이 위에 기존 webview와 동일한 JS 인터페이스를 구성
    const js_code =
        \\(function() {
        \\  var raw_invoke = window.__suji__.invoke;
        \\  var raw_emit = window.__suji__.emit;
        \\  var s = window.__suji__;
        \\  s._pending = {};
        \\  s._early = {};
        \\  s._finishResolve = function(p, json) {
        \\    try { p.resolve(JSON.parse(json)); } catch(e) { p.resolve(json); }
        \\  };
        \\  s._promiseFor = function(seq) {
        \\    return new Promise(function(resolve, reject) {
        \\      if (typeof seq !== "number") {
        \\        reject(new Error("invoke failed before browser dispatch"));
        \\        return;
        \\      }
        \\      var early = s._early[seq];
        \\      if (early) {
        \\        delete s._early[seq];
        \\        if (early.ok) s._finishResolve({ resolve: resolve }, early.value);
        \\        else reject(new Error(early.value));
        \\        return;
        \\      }
        \\      s._pending[seq] = { resolve: resolve, reject: reject };
        \\    });
        \\  };
        \\  s._nextResolve = function(seq, json) {
        \\    var p = s._pending[seq];
        \\    if (p) { delete s._pending[seq]; s._finishResolve(p, json); }
        \\    else s._early[seq] = { ok: true, value: json };
        \\  };
        \\  s._nextReject = function(seq, err) {
        \\    var p = s._pending[seq];
        \\    if (p) { delete s._pending[seq]; p.reject(new Error(err)); }
        \\    else s._early[seq] = { ok: false, value: err };
        \\  };
        \\  s._chunks = {};
        \\  s._nextChunk = function(seq, idx, total, data) {
        \\    var st = s._chunks[seq];
        \\    if (!st) { st = s._chunks[seq] = { parts: new Array(total), got: 0 }; }
        \\    if (idx >= 0 && idx < total && st.parts[idx] === undefined) { st.parts[idx] = data; st.got++; }
        \\  };
        \\  s._chunkComplete = function(seq, success) {
        \\    var st = s._chunks[seq];
        \\    var full = st ? st.parts.join('') : '';
        \\    delete s._chunks[seq];
        \\    if (success) s._nextResolve(seq, full);
        \\    else s._nextReject(seq, full);
        \\  };
        \\  s.invoke = function(channel, data, options) {
        \\    var req = data ? Object.assign({cmd: channel}, data) : {cmd: channel};
        \\    var target = options && options.target;
        \\    var seq = raw_invoke(target || channel, JSON.stringify(req));
        \\    return s._promiseFor(seq);
        \\  };
        \\  s.emit = function(event, data, target) {
        \\    return raw_emit(event, JSON.stringify(data || {}), target);
        \\  };
        \\  s.chain = function(from, to, request) {
        \\    var seq = raw_invoke("__chain__", JSON.stringify({__chain:true,from:from,to:to,request:request}));
        \\    return s._promiseFor(seq);
        \\  };
        \\  s.fanout = function(backends, request) {
        \\    var seq = raw_invoke("__fanout__", JSON.stringify({__fanout:true,backends:backends,request:request}));
        \\    return s._promiseFor(seq);
        \\  };
        \\  s.core = function(request) {
        \\    var seq = raw_invoke("__core__", JSON.stringify({__core:true,request:request}));
        \\    return s._promiseFor(seq);
        \\  };
        \\  s._listeners = {};
        \\  s.on = function(event, callback) {
        \\    if (!s._listeners[event]) s._listeners[event] = [];
        \\    s._listeners[event].push(callback);
        \\    return function() {
        \\      var idx = s._listeners[event].indexOf(callback);
        \\      if (idx >= 0) s._listeners[event].splice(idx, 1);
        \\    };
        \\  };
        \\  s.off = function(event) {
        \\    delete s._listeners[event];
        \\  };
        \\  s.__dispatch__ = function(event, data) {
        \\    var cbs = s._listeners[event] || [];
        \\    for (var i = 0; i < cbs.length; i++) cbs[i](data);
        \\  };
        \\  // Electron 호환: quit() / platform
        \\  s.quit = function() {
        \\    raw_invoke("__core__", JSON.stringify({__core:true,request:JSON.stringify({cmd:"quit"})}));
        \\  };
        \\})();
    ;

    // Platform 주입 + contextIsolation 하드닝을 js_code 와 *하나의* eval 로 합침.
    // 순서: IIFE(메서드 구성) → platform 대입(아직 가변) → Object.freeze(메서드
    // 재할당/추가/삭제 차단) → window 슬롯 non-writable/non-configurable(통째
    // 교체/삭제 차단). 단일 문자열·동일 컨텍스트·동일 순서라 2-eval 과 의미 동일
    // (IIFE 가 먼저 s.* 구성 → 이후 bootstrap 문이 그 위에서 freeze).
    // shallow freeze 라 _pending/_listeners inner 객체는 가변 → invoke/on/off
    // 정상. 보안 한계는 docs/PLAN Phase 7 (메인 월드 frozen, isolated-world 아님).
    //
    // ⚠️ 하드 불변식: onContextCreated 경로의 ctx.eval 은 **정확히 1회**.
    // ctx.eval 을 추가로 호출(여기 분리 복원 / 별도 eval 추가)하면 CEF inspector
    // attach 가 30s(protocolTimeout) 행 — 실측 회귀. 단일 eval 로 합쳐 "정확히 N회"
    // 인지 함정을 제거(분리하지 말 것). 가드: e2e set-user-agent (protocolTimeout
    // 30000 — 회귀 시 즉시 행으로 실패). 추가 JS 는 별도 eval 이 아니라 이
    // combined_js 문자열에 이어붙일 것.
    const bootstrap_js = "window.__suji__.platform = \"" ++ comptime platformLiteral() ++ "\";" ++
        "Object.freeze(window.__suji__);" ++
        "try{Object.defineProperty(window,\"__suji__\",{value:window.__suji__,writable:false,configurable:false,enumerable:false});}catch(e){}";
    const combined_js = js_code ++ bootstrap_js;

    var code_str: c.cef_string_t = .{};
    setCefString(&code_str, combined_js);
    var empty_url: c.cef_string_t = .{};
    setCefString(&empty_url, "");
    var retval: ?*c.cef_v8_value_t = null;
    var exception: ?*c.cef_v8_exception_t = null;
    _ = ctx.eval.?(ctx, &code_str, &empty_url, 0, &retval, &exception);
}

/// 컴파일타임 플랫폼 문자열 (V8 바인딩의 window.__suji__.platform 값).
fn platformLiteral() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => @compileError("Suji: unsupported OS"),
    };
}
