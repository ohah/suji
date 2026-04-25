// Suji Node.js Bridge — C++ implementation
// Embeds Node.js runtime using official embedding API

#include <node.h>
#include <uv.h>
#include "bridge.h"

#include <string>
#include <memory>
#include <atomic>
#include <cstring>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <unordered_map>
#include <queue>
#include <functional>

// JSON 문자열 값에 사용할 수 없는 문자를 이스케이프
static std::string escape_json(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:   out += c;
        }
    }
    return out;
}

// JS 문자열 리터럴('...')에 사용할 수 없는 문자를 이스케이프
static std::string escape_js_single(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '\'': out += "\\'";  break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            default:   out += c;
        }
    }
    return out;
}

using node::CommonEnvironmentSetup;
using node::Environment;
using node::MultiIsolatePlatform;
using v8::Context;
using v8::Function;
using v8::Global;
using v8::HandleScope;
using v8::Isolate;
using v8::Local;
using v8::Locker;
using v8::String;
using v8::Value;

// ============================================
// Global state
// ============================================

static std::unique_ptr<MultiIsolatePlatform> g_platform;
static std::unique_ptr<CommonEnvironmentSetup> g_setup;
static std::atomic<bool> g_running{false};
static std::atomic<bool> g_initialized{false};
static std::atomic<bool> g_ready{false};
static std::mutex g_ready_mutex;
static std::condition_variable g_ready_cv;
static std::thread g_thread;

// IPC 핸들러 맵 (channel → JS function)
static std::unordered_map<std::string, Global<Function>> g_handlers;
static std::mutex g_handler_mutex;

// SujiCore (크로스 호출 + 이벤트)
static SujiNodeCore g_core = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};

// IPC 요청/응답 큐 (스레드 간 통신)
struct IpcRequest {
    std::string channel;
    std::string data;
    std::string response;
    bool done = false;
    std::mutex mtx;
    std::condition_variable cv;
};

static std::mutex g_ipc_mutex;
static std::vector<IpcRequest*> g_ipc_queue;
static uv_async_t g_ipc_async;

// Node main thread가 invokeSync로 block 중인지 표시.
// 재진입 경로(다른 backend가 다시 Node로 invoke)에서 큐 대신 inline 실행 판단에 사용.
static thread_local bool g_in_sync_invoke = false;

// Async invoke: JS→백엔드 비동기 호출 (Promise 반환)
struct AsyncInvokeRequest {
    std::string backend;
    std::string request;
    std::string response;
    bool success = false;
    v8::Global<v8::Promise::Resolver> resolver;
};

static std::mutex g_async_invoke_mutex;
static std::vector<AsyncInvokeRequest*> g_async_invoke_done;
static uv_async_t g_async_invoke_async;

// Event listener: C 콜백 → Node 스레드 전달
struct EventNotification {
    std::string channel;
    std::string data;
};

struct JsEventListener {
    uint64_t sub_id;
    v8::Global<v8::Function> callback;
};

static std::mutex g_event_mutex;
static std::vector<EventNotification*> g_event_queue;
static uv_async_t g_event_async;
static std::mutex g_listener_mutex;
static std::vector<JsEventListener*> g_listeners;

// ============================================
// Thread Pool (async invoke용, 고정 크기)
// ============================================

class ThreadPool {
public:
    explicit ThreadPool(size_t num_threads) : stop_(false) {
        for (size_t i = 0; i < num_threads; ++i) {
            workers_.emplace_back([this]() {
                while (true) {
                    std::function<void()> task;
                    {
                        std::unique_lock<std::mutex> lock(mtx_);
                        cv_.wait(lock, [this]() { return stop_ || !tasks_.empty(); });
                        if (stop_ && tasks_.empty()) return;
                        task = std::move(tasks_.front());
                        tasks_.pop();
                    }
                    task();
                }
            });
        }
    }

    void submit(std::function<void()> task) {
        {
            std::lock_guard<std::mutex> lock(mtx_);
            tasks_.push(std::move(task));
        }
        cv_.notify_one();
    }

    ~ThreadPool() {
        {
            std::lock_guard<std::mutex> lock(mtx_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto& w : workers_) w.join();
    }

private:
    std::vector<std::thread> workers_;
    std::queue<std::function<void()>> tasks_;
    std::mutex mtx_;
    std::condition_variable cv_;
    bool stop_;
};

static std::unique_ptr<ThreadPool> g_invoke_pool;

// ============================================
// Event 큐 처리 (Node event loop에서 JS 콜백 호출)
// ============================================

static void process_event_queue(uv_async_t*) {
    if (!g_setup) return;
    Isolate* isolate = g_setup->isolate();
    if (!isolate) return;

    Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Context::Scope context_scope(g_setup->context());

    std::vector<EventNotification*> events;
    {
        std::lock_guard<std::mutex> lock(g_event_mutex);
        events.swap(g_event_queue);
    }

    std::vector<JsEventListener*> listeners;
    {
        std::lock_guard<std::mutex> lock(g_listener_mutex);
        listeners = g_listeners; // 복사 (콜백 실행 중 수정 방지)
    }

    for (auto* evt : events) {
        for (auto* listener : listeners) {
            // 채널 매칭: 리스너가 특정 채널 또는 전체(*)를 수신
            Local<Function> fn = listener->callback.Get(isolate);
            Local<String> ch_arg = String::NewFromUtf8(isolate, evt->channel.c_str()).ToLocalChecked();
            Local<String> data_arg = String::NewFromUtf8(isolate, evt->data.c_str()).ToLocalChecked();
            Local<Value> argv[2] = { ch_arg, data_arg };

            v8::TryCatch try_catch(isolate);
            fn->Call(g_setup->context(), v8::Undefined(isolate), 2, argv).FromMaybe(Local<Value>());
            if (try_catch.HasCaught()) {
                String::Utf8Value err(isolate, try_catch.Exception());
                fprintf(stderr, "[suji-node] event callback error: %s\n", *err);
            }
        }
        delete evt;
    }
}

// C 콜백 — EventBus에서 호출됨 (임의 스레드)
static void on_event_callback(const char* channel, const char* data, void*) {
    auto* evt = new EventNotification();
    evt->channel = channel ? channel : "";
    evt->data = data ? data : "";
    {
        std::lock_guard<std::mutex> lock(g_event_mutex);
        g_event_queue.push_back(evt);
    }
    uv_async_send(&g_event_async);
}

// ============================================
// 단일 IPC 요청 실행 (V8 isolate lock + context scope 안에서 호출)
// ============================================

// "key":"<value>" 형식에서 value 추출 (이스케이프 \" / \\ 처리).
// 매칭 실패 시 found=false. 매칭 성공이면 *out에 파싱된 string 채워짐.
static bool extract_string_field(const std::string& data, const std::string& key_with_quotes, std::string* out) {
    size_t pos = data.find(key_with_quotes);
    if (pos == std::string::npos) return false;
    size_t p = pos + key_with_quotes.size();
    out->clear();
    while (p < data.size()) {
        char c = data[p];
        if (c == '\\' && p + 1 < data.size()) {
            out->push_back(data[p + 1]);
            p += 2;
            continue;
        }
        if (c == '"') return true;
        out->push_back(c);
        p++;
    }
    return true; // 종결 quote 못 찾았어도 부분값은 그대로 반환 (defensive)
}

// "key":true|false 추출. 매칭 실패/잘못된 값은 false 반환 + *out 미변경.
static bool extract_bool_field(const std::string& data, const std::string& key_with_colon, bool* out) {
    size_t pos = data.find(key_with_colon);
    if (pos == std::string::npos) return false;
    size_t p = pos + key_with_colon.size();
    while (p < data.size() && data[p] == ' ') p++;
    if (p + 4 <= data.size() && data.compare(p, 4, "true") == 0) { *out = true; return true; }
    if (p + 5 <= data.size() && data.compare(p, 5, "false") == 0) { *out = false; return true; }
    return false;
}

// wire의 __window / __window_name / __window_url / __window_main_frame 에서 `{window: {...}}` 객체 구성.
// JSON 파싱 없이 간단 파서 — compact wire 포맷 가정 (Suji 코어 주입 결과). 매칭 실패는 default(0/null).
static Local<Value> build_invoke_event(Isolate* isolate, const std::string& data) {
    Local<v8::Context> ctx = g_setup->context();
    Local<v8::Object> window = v8::Object::New(isolate);

    // __window는 항상 가장 먼저 박힘 — 못 찾으면 나머지도 없으므로 early-return으로 3회 find 스킵.
    uint32_t id = 0;
    {
        const std::string key = "\"__window\":";
        size_t pos = data.find(key);
        if (pos == std::string::npos) {
            // 코어 미경유 또는 cross-hop 보존 케이스. id=0, 모든 필드 null로 emit.
            window->Set(ctx, String::NewFromUtf8(isolate, "id").ToLocalChecked(),
                        v8::Integer::NewFromUnsigned(isolate, 0)).Check();
            window->Set(ctx, String::NewFromUtf8(isolate, "name").ToLocalChecked(), v8::Null(isolate)).Check();
            window->Set(ctx, String::NewFromUtf8(isolate, "url").ToLocalChecked(), v8::Null(isolate)).Check();
            window->Set(ctx, String::NewFromUtf8(isolate, "is_main_frame").ToLocalChecked(), v8::Null(isolate)).Check();
            Local<v8::Object> event = v8::Object::New(isolate);
            event->Set(ctx, String::NewFromUtf8(isolate, "window").ToLocalChecked(), window).Check();
            return event;
        }
        size_t p = pos + key.size();
        while (p < data.size() && data[p] == ' ') p++;
        while (p < data.size() && data[p] >= '0' && data[p] <= '9') {
            id = id * 10 + (data[p] - '0');
            p++;
        }
    }

    std::string name, url;
    bool has_name = extract_string_field(data, "\"__window_name\":\"", &name);
    bool has_url = extract_string_field(data, "\"__window_url\":\"", &url);
    bool main_frame_b = false;
    bool has_main_frame = extract_bool_field(data, "\"__window_main_frame\":", &main_frame_b);

    auto set_str_or_null = [&](const char* k, bool has, const std::string& v) {
        Local<Value> val = has
            ? Local<Value>::Cast(String::NewFromUtf8(isolate, v.c_str()).ToLocalChecked())
            : Local<Value>::Cast(v8::Null(isolate));
        window->Set(ctx, String::NewFromUtf8(isolate, k).ToLocalChecked(), val).Check();
    };

    window->Set(ctx, String::NewFromUtf8(isolate, "id").ToLocalChecked(),
                v8::Integer::NewFromUnsigned(isolate, id)).Check();
    set_str_or_null("name", has_name, name);
    set_str_or_null("url", has_url, url);
    Local<Value> main_frame_val = has_main_frame
        ? Local<Value>::Cast(v8::Boolean::New(isolate, main_frame_b))
        : Local<Value>::Cast(v8::Null(isolate));
    window->Set(ctx, String::NewFromUtf8(isolate, "is_main_frame").ToLocalChecked(),
                main_frame_val).Check();

    Local<v8::Object> event = v8::Object::New(isolate);
    event->Set(ctx, String::NewFromUtf8(isolate, "window").ToLocalChecked(), window).Check();
    return event;
}

static void execute_ipc_request(Isolate* isolate, IpcRequest* req) {
    HandleScope handle_scope(isolate);
    std::string result = "{\"error\":\"no handler\"}";

    Local<Function> fn_local;
    bool found = false;
    {
        std::lock_guard<std::mutex> lock(g_handler_mutex);
        auto it = g_handlers.find(req->channel);
        if (it != g_handlers.end()) {
            fn_local = it->second.Get(isolate);
            found = true;
        }
    }

    if (found) {
        // arg[0]: data 문자열 (JS 측 1-arity wrapper가 JSON.parse).
        // arg[1]: event 객체 — wire의 __window/__window_name에서 파생. 2-arity 핸들러용.
        //   1-arity handler는 두 번째 인자를 무시하므로 호환 OK.
        Local<String> arg = String::NewFromUtf8(isolate, req->data.c_str()).ToLocalChecked();
        Local<Value> event = build_invoke_event(isolate, req->data);
        Local<Value> argv[2] = { arg, event };

        v8::TryCatch try_catch(isolate);
        auto maybe_result = fn_local->Call(g_setup->context(), v8::Undefined(isolate), 2, argv);

        if (!maybe_result.IsEmpty()) {
            Local<Value> ret = maybe_result.ToLocalChecked();
            if (ret->IsString()) {
                String::Utf8Value utf8(isolate, ret);
                result = std::string(*utf8, utf8.length());
            } else {
                Local<Value> json_global;
                if (g_setup->context()->Global()->Get(g_setup->context(), String::NewFromUtf8(isolate, "JSON").ToLocalChecked()).ToLocal(&json_global) && json_global->IsObject()) {
                    Local<Value> stringify_fn;
                    if (json_global.As<v8::Object>()->Get(g_setup->context(), String::NewFromUtf8(isolate, "stringify").ToLocalChecked()).ToLocal(&stringify_fn) && stringify_fn->IsFunction()) {
                        Local<Value> str_argv[1] = { ret };
                        auto str_result = stringify_fn.As<Function>()->Call(g_setup->context(), json_global, 1, str_argv);
                        if (!str_result.IsEmpty()) {
                            String::Utf8Value utf8s(isolate, str_result.ToLocalChecked());
                            result = std::string(*utf8s, utf8s.length());
                        }
                    }
                }
            }
        } else if (try_catch.HasCaught()) {
            String::Utf8Value err(isolate, try_catch.Exception());
            result = std::string("{\"error\":\"") + escape_json(*err) + "\"}";
        }
    }

    {
        std::lock_guard<std::mutex> lock(req->mtx);
        req->response = std::move(result);
        req->done = true;
    }
    req->cv.notify_one();
}

// ============================================
// Async invoke 결과 처리 (Node event loop에서 Promise resolve)
// ============================================

static void process_async_invoke_done(uv_async_t*) {
    if (!g_setup) return;
    Isolate* isolate = g_setup->isolate();
    if (!isolate) return;

    Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Context::Scope context_scope(g_setup->context());

    std::vector<AsyncInvokeRequest*> done;
    {
        std::lock_guard<std::mutex> lock(g_async_invoke_mutex);
        done.swap(g_async_invoke_done);
    }

    for (auto* req : done) {
        auto resolver = req->resolver.Get(isolate);
        auto str = String::NewFromUtf8(isolate, req->response.c_str()).ToLocalChecked();
        if (req->success) {
            resolver->Resolve(g_setup->context(), str).FromMaybe(false);
        } else {
            resolver->Reject(g_setup->context(), str).FromMaybe(false);
        }
        delete req;
    }
}

// ============================================
// IPC 처리 (메인 Node 스레드에서 실행)
// ============================================

static void process_ipc_queue(uv_async_t*) {
    if (!g_setup) return;
    Isolate* isolate = g_setup->isolate();
    if (!isolate) return;

    Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Context::Scope context_scope(g_setup->context());

    std::vector<IpcRequest*> pending;
    {
        std::lock_guard<std::mutex> lock(g_ipc_mutex);
        pending.swap(g_ipc_queue);
    }

    for (auto* req : pending) {
        execute_ipc_request(isolate, req);
    }
}

// ============================================
// JS에서 호출하는 네이티브 함수: __suji_handle(channel, fn)
// ============================================

static void js_suji_handle(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (args.Length() < 2 || !args[0]->IsString() || !args[1]->IsFunction()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.handle(channel, fn) requires string and function").ToLocalChecked());
        return;
    }

    String::Utf8Value channel(isolate, args[0]);
    std::string ch(*channel, channel.length());

    Local<Function> fn = args[1].As<Function>();

    std::lock_guard<std::mutex> lock(g_handler_mutex);
    g_handlers[ch] = Global<Function>(isolate, fn);

    fprintf(stderr, "[suji-node] handler registered: %s\n", ch.c_str());
}

// ============================================
// JS에서 호출하는 네이티브 함수: __suji_invoke(backend, request) → string
// ============================================

// Node event loop 스레드에서 직접 IPC 큐의 pending 요청을 처리
// invokeSync 내에서 대상 백엔드가 Node로 콜백할 때 deadlock 방지
static void drain_ipc_queue_inline() {
    if (!g_setup) return;
    Isolate* isolate = g_setup->isolate();

    std::vector<IpcRequest*> pending;
    {
        std::lock_guard<std::mutex> lock(g_ipc_mutex);
        pending.swap(g_ipc_queue);
    }
    if (pending.empty()) return;

    for (auto* req : pending) {
        execute_ipc_request(isolate, req);
    }
}

// suji.invokeSync(backend, request) → string (동기, 핸들러 내부용)
//
// 양방향 크로스콜 deadlock 방지 전략:
//
// 1. 동일 스레드 재귀 (Zig → Rust → Go → Node 동기 체인):
//    g_in_sync_invoke thread_local 플래그로 감지해서 suji_node_invoke가
//    inline(V8 Locker 재진입) 경로로 빠짐. 이 경로는 js_suji_invoke_sync가
//    어차피 이 스레드에서 block 중이므로 큐/event loop 불필요.
//
// 2. 다른 스레드 재진입 (Rust가 std::thread::spawn으로 Node 재진입 등):
//    워커 스레드에서 g_core.invoke를 실행하고, Node main thread는 완료될 때까지
//    polling하며 큐를 주기적으로 drain. 외부 스레드가 queue에 push한 요청을
//    main이 처리해줘야 워커의 invoke가 리턴된다.
//
// V8 Locker는 polling 중 다른 스레드가 isolate를 쓸 수 있게 잠시 놓아주지 않으면
// 안 된다 (process_ipc_queue 등은 uv_async_send로 깨어나 자체적으로 Locker 잡음 —
// 하지만 js_suji_invoke_sync가 Locker를 계속 쥐고 있으면 Blocked). 따라서 polling
// 구간에서는 Unlocker로 isolate를 놓아주고, drain 직전/직후만 명시적으로 다시 잡는다.
static void js_suji_invoke_sync(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!g_core.invoke) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.invokeSync: core not connected").ToLocalChecked());
        return;
    }
    if (args.Length() < 2 || !args[0]->IsString() || !args[1]->IsString()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.invokeSync(backend, request) requires two strings").ToLocalChecked());
        return;
    }

    String::Utf8Value backend_utf(isolate, args[0]);
    String::Utf8Value request_utf(isolate, args[1]);
    std::string backend_str(*backend_utf, backend_utf.length());
    std::string request_str(*request_utf, request_utf.length());

    // 워커 스레드에서 g_core.invoke 실행, main thread는 drain polling.
    std::atomic<bool> done{false};
    std::string result_str;
    bool has_result = false;

    std::thread worker([&]() {
        // 워커 스레드도 체인 내 재진입 inline 경로를 쓸 수 있게 플래그 설정.
        // (워커에서 Zig/Rust/Go를 통해 다시 Node로 들어오는 동기 체인 대비)
        g_in_sync_invoke = true;
        const char* r = g_core.invoke(backend_str.c_str(), request_str.c_str());
        g_in_sync_invoke = false;
        if (r) {
            result_str.assign(r);
            g_core.free(r);
            has_result = true;
        }
        done.store(true, std::memory_order_release);
    });

    // Main thread: worker가 끝날 때까지 큐 drain 반복.
    // Unlocker로 V8 locker를 놓아야 다른 스레드의 process_ipc_queue가 Locker를
    // 잡을 수 있다. 우리가 drain_ipc_queue_inline을 직접 호출할 때만 다시 잡는다.
    while (!done.load(std::memory_order_acquire)) {
        {
            v8::Unlocker unlocker(isolate);
            // 다른 스레드에서 uv_async_send가 Node event loop를 깨우고
            // process_ipc_queue가 돌 수 있는 틈을 줌.
            std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
        // 추가 안전장치: 우리가 직접 inline drain (process_ipc_queue와 중복 safe,
        // swap으로 큐를 비움).
        drain_ipc_queue_inline();
    }
    worker.join();

    if (has_result) {
        args.GetReturnValue().Set(String::NewFromUtf8(isolate, result_str.c_str()).ToLocalChecked());
    } else {
        args.GetReturnValue().SetNull();
    }
}

// suji.invoke(backend, request) → Promise<string>
// 별도 스레드에서 g_core.invoke를 호출하고, 완료 시 Node event loop에서 resolve.
// event loop를 블록하지 않으므로 deadlock 위험 없음.
static void js_suji_invoke(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!g_core.invoke) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.invoke: core not connected").ToLocalChecked());
        return;
    }
    if (args.Length() < 2 || !args[0]->IsString() || !args[1]->IsString()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.invoke(backend, request) requires two strings").ToLocalChecked());
        return;
    }

    String::Utf8Value backend(isolate, args[0]);
    String::Utf8Value request(isolate, args[1]);

    auto resolver = v8::Promise::Resolver::New(g_setup->context()).ToLocalChecked();
    args.GetReturnValue().Set(resolver->GetPromise());

    auto* async_req = new AsyncInvokeRequest();
    async_req->backend = std::string(*backend, backend.length());
    async_req->request = std::string(*request, request.length());
    async_req->resolver.Reset(isolate, resolver);

    if (!g_invoke_pool) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.invoke: thread pool not initialized").ToLocalChecked());
        return;
    }

    g_invoke_pool->submit([async_req]() {
        const char* result = g_core.invoke(async_req->backend.c_str(), async_req->request.c_str());
        if (result) {
            async_req->response = result;
            async_req->success = true;
            g_core.free(result);
        } else {
            async_req->response = "invoke returned null";
            async_req->success = false;
        }

        {
            std::lock_guard<std::mutex> lock(g_async_invoke_mutex);
            g_async_invoke_done.push_back(async_req);
        }
        uv_async_send(&g_async_invoke_async);
    });
}

// ============================================
// JS에서 호출하는 네이티브 함수: __suji_send(channel, data)
// ============================================

static void js_suji_send(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!g_core.emit) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.send: core not connected").ToLocalChecked());
        return;
    }
    if (args.Length() < 2 || !args[0]->IsString() || !args[1]->IsString()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.send(channel, data) requires two strings").ToLocalChecked());
        return;
    }

    String::Utf8Value channel(isolate, args[0]);
    String::Utf8Value data(isolate, args[1]);

    g_core.emit(*channel, *data);
}

// ============================================
// JS에서 호출하는 네이티브 함수: __suji_emit_to(windowId, channel, data)
// Electron webContents.send 대응. windowId는 uint32 (WindowManager id).
// ============================================

static void js_suji_emit_to(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!g_core.emit_to) {
        // core 주입 전 또는 구버전 core — silent no-op (SDK/core 버전 불일치 방어).
        return;
    }
    if (args.Length() < 3 || !args[0]->IsUint32() || !args[1]->IsString() || !args[2]->IsString()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.sendTo(windowId, channel, data) requires (uint32, string, string)").ToLocalChecked());
        return;
    }

    uint32_t window_id = args[0]->Uint32Value(g_setup->context()).FromMaybe(0);
    String::Utf8Value channel(isolate, args[1]);
    String::Utf8Value data(isolate, args[2]);

    g_core.emit_to(window_id, *channel, *data);
}

// ============================================
// JS에서 호출하는 네이티브 함수: __suji_register(channel)
// ============================================

static void js_suji_register(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!g_core.reg) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.register: core not connected").ToLocalChecked());
        return;
    }
    if (args.Length() < 1 || !args[0]->IsString()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.register(channel) requires string").ToLocalChecked());
        return;
    }

    String::Utf8Value channel(isolate, args[0]);
    g_core.reg(*channel);
}

// ============================================
// __suji_quit() / __suji_platform() — Electron 호환 API
// ============================================

static void js_suji_quit(const v8::FunctionCallbackInfo<Value>& args) {
    (void)args;
    if (g_core.quit) g_core.quit();
    // core 미연결 상태는 silent no-op (SDK robustness).
}

static void js_suji_platform(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    const char* name = (g_core.platform != nullptr) ? g_core.platform() : "unknown";
    args.GetReturnValue().Set(
        String::NewFromUtf8(isolate, name ? name : "unknown").ToLocalChecked()
    );
}

// ============================================
// JS에서 호출하는 네이티브 함수: __suji_on(channel, callback) → subId
// ============================================

static void js_suji_on(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!g_core.on) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.on: core not connected").ToLocalChecked());
        return;
    }
    if (args.Length() < 2 || !args[0]->IsString() || !args[1]->IsFunction()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.on(channel, callback) requires string and function").ToLocalChecked());
        return;
    }

    String::Utf8Value channel(isolate, args[0]);

    // JS 콜백을 Global로 저장
    auto* listener = new JsEventListener();
    listener->callback.Reset(isolate, args[1].As<Function>());

    // C 콜백으로 EventBus에 등록 (임의 스레드에서 호출됨 → on_event_callback이 큐에 전달)
    uint64_t sub_id = g_core.on(*channel, on_event_callback, nullptr);
    listener->sub_id = sub_id;

    {
        std::lock_guard<std::mutex> lock(g_listener_mutex);
        g_listeners.push_back(listener);
    }

    // subscription ID 반환 (off에서 사용)
    args.GetReturnValue().Set(v8::Number::New(isolate, static_cast<double>(sub_id)));
}

// ============================================
// JS에서 호출하는 네이티브 함수: __suji_off(subId)
// ============================================

static void js_suji_off(const v8::FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    if (!g_core.off) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.off: core not connected").ToLocalChecked());
        return;
    }
    if (args.Length() < 1 || !args[0]->IsNumber()) {
        isolate->ThrowException(String::NewFromUtf8(isolate, "suji.off(subId) requires number").ToLocalChecked());
        return;
    }

    uint64_t sub_id = static_cast<uint64_t>(args[0]->NumberValue(g_setup->context()).FromJust());

    // EventBus에서 구독 해제
    g_core.off(sub_id);

    // JS 리스너 정리
    {
        std::lock_guard<std::mutex> lock(g_listener_mutex);
        g_listeners.erase(
            std::remove_if(g_listeners.begin(), g_listeners.end(),
                [sub_id](JsEventListener* l) {
                    if (l->sub_id == sub_id) {
                        l->callback.Reset();
                        delete l;
                        return true;
                    }
                    return false;
                }),
            g_listeners.end()
        );
    }
}

// ============================================
// C API Implementation
// ============================================

extern "C" {

int suji_node_init(int argc, char** argv) {
    if (g_initialized.load()) return 0;

    std::vector<std::string> args(argv, argv + argc);

    auto result = node::InitializeOncePerProcess(args, {
        node::ProcessInitializationFlags::kNoInitializeV8,
        node::ProcessInitializationFlags::kNoInitializeNodeV8Platform,
    });

    if (result->early_return() != 0) {
        return -1;
    }

    g_platform = MultiIsolatePlatform::Create(4);
    v8::V8::InitializePlatform(g_platform.get());
    v8::V8::Initialize();

    g_initialized.store(true);
    return 0;
}

static int run_node_internal(const char* entry_path) {
    std::vector<std::string> args = {"suji-node"};
    std::vector<std::string> exec_args;
    std::vector<std::string> errors;

    g_setup = CommonEnvironmentSetup::Create(
        g_platform.get(), &errors, args, exec_args);

    if (!g_setup) {
        for (const auto& e : errors) {
            fprintf(stderr, "[suji-node] setup error: %s\n", e.c_str());
        }
        return -1;
    }

    Isolate* isolate = g_setup->isolate();
    Environment* env = g_setup->env();

    {
        Locker locker(isolate);
        Isolate::Scope isolate_scope(isolate);
        HandleScope handle_scope(isolate);
        Context::Scope context_scope(g_setup->context());

        // process.exit() 크래시 방지
        node::SetProcessExitHandler(env, [](Environment* e, int code) {
            node::Stop(e);
        });

        // IPC async 핸들 등록 (Node 이벤트 루프에서 IPC 처리)
        uv_async_init(g_setup->event_loop(), &g_ipc_async, process_ipc_queue);
        uv_async_init(g_setup->event_loop(), &g_async_invoke_async, process_async_invoke_done);
        uv_async_init(g_setup->event_loop(), &g_event_async, process_event_queue);

        // Async invoke 스레드 풀 (4 workers)
        g_invoke_pool = std::make_unique<ThreadPool>(4);

        // globalThis 네이티브 함수 등록
        auto set_fn = [&](const char* name, v8::FunctionCallback cb) {
            Local<v8::FunctionTemplate> tmpl = v8::FunctionTemplate::New(isolate, cb);
            g_setup->context()->Global()->Set(
                g_setup->context(),
                String::NewFromUtf8(isolate, name).ToLocalChecked(),
                tmpl->GetFunction(g_setup->context()).ToLocalChecked()
            ).Check();
        };
        set_fn("__suji_handle", js_suji_handle);
        set_fn("__suji_invoke", js_suji_invoke);
        set_fn("__suji_invoke_sync", js_suji_invoke_sync);
        set_fn("__suji_send", js_suji_send);
        set_fn("__suji_emit_to", js_suji_emit_to);
        set_fn("__suji_on", js_suji_on);
        set_fn("__suji_off", js_suji_off);
        set_fn("__suji_register", js_suji_register);
        set_fn("__suji_quit", js_suji_quit);
        set_fn("__suji_platform", js_suji_platform);

        // 엔트리 JS 파일 로드 — @suji/node SDK를 주입하고 사용자 코드 실행
        std::string safe_path = escape_js_single(entry_path);
        std::string code = std::string(
            "globalThis.suji = {"
            "  handle: __suji_handle,"
            "  invoke: __suji_invoke,"
            "  invokeSync: __suji_invoke_sync,"
            "  send: __suji_send,"
            "  sendTo: __suji_emit_to,"
            "  on: __suji_on,"
            "  off: __suji_off,"
            "  register: __suji_register,"
            "  quit: __suji_quit,"
            "  platform: __suji_platform"
            "};"
            "const { createRequire } = require('module');"
            "const r = createRequire('") + safe_path + "');"
            "r('" + safe_path + "');";

        auto load_result = node::LoadEnvironment(env, code.c_str());

        if (load_result.IsEmpty()) {
            fprintf(stderr, "[suji-node] failed to load: %s\n", entry_path);
            return -1;
        }

        g_running.store(true);

        // 엔트리 로드 완료 = 핸들러 등록 완료 → ready 시그널
        {
            std::lock_guard<std::mutex> lock(g_ready_mutex);
            g_ready.store(true);
        }
        g_ready_cv.notify_all();

        node::SpinEventLoop(env).FromMaybe(1);
        g_running.store(false);

        // ThreadPool을 V8 isolate scope 안에서 정리 (in-flight 작업 완료 대기)
        g_invoke_pool.reset();

        // async 핸들을 닫아야 g_setup 파괴 시 uv_loop_close가 "open handles"로
        // abort하지 않는다. uv_close는 async라 loop를 한 번 더 돌려 close 콜백
        // 처리까지 해줘야 uv_loop가 alive=0이 됨.
        uv_close(reinterpret_cast<uv_handle_t*>(&g_ipc_async), nullptr);
        uv_close(reinterpret_cast<uv_handle_t*>(&g_async_invoke_async), nullptr);
        uv_close(reinterpret_cast<uv_handle_t*>(&g_event_async), nullptr);
        uv_loop_t* loop = g_setup->event_loop();
        while (uv_run(loop, UV_RUN_NOWAIT) != 0) {}
    }

    node::Stop(env);
    g_handlers.clear();
    g_setup.reset();
    return 0;
}

int suji_node_run(const char* entry_path) {
    if (!g_initialized.load()) return -1;
    return run_node_internal(entry_path);
}

int suji_node_run_async(const char* entry_path) {
    if (!g_initialized.load()) return -1;
    std::string path(entry_path);
    g_thread = std::thread([path]() {
        run_node_internal(path.c_str());
    });
    return 0;
}

void suji_node_stop(void) {
    if (g_setup && g_running.load()) {
        Environment* env = g_setup->env();
        if (env) node::Stop(env);
    }
    if (g_thread.joinable()) g_thread.join();
}

void suji_node_shutdown(void) {
    suji_node_stop();
    g_invoke_pool.reset(); // run_node_internal에서 이미 정리했으면 no-op
    g_handlers.clear();
    g_setup.reset();
    g_ready.store(false);
    if (g_initialized.load()) {
        v8::V8::Dispose();
        v8::V8::DisposePlatform();
        g_platform.reset();
        node::TearDownOncePerProcess();
        g_initialized.store(false);
    }
}

int suji_node_wait_ready(int timeout_ms) {
    if (g_ready.load()) return 0;
    std::unique_lock<std::mutex> lock(g_ready_mutex);
    if (timeout_ms <= 0) {
        g_ready_cv.wait(lock, []() { return g_ready.load(); });
    } else {
        if (!g_ready_cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), []() { return g_ready.load(); })) {
            return -1; // timeout
        }
    }
    return 0;
}

const char* suji_node_invoke(const char* channel, const char* data) {
    if (!g_running.load()) return strdup("{\"error\":\"node not running\"}");

    // 재진입 경로: Node main thread가 이미 invokeSync로 block 중이면,
    // 큐에 넣어도 event loop가 돌 수 없어 영원히 처리 안 됨. 현재 스레드가
    // Node main thread 그 자체(체인이 같은 프로세스에서 동기로 내려옴)이므로
    // V8은 이미 locked 상태. 직접 handler를 호출해서 결과를 리턴한다.
    if (g_in_sync_invoke && g_setup) {
        Isolate* isolate = g_setup->isolate();
        // Locker는 같은 스레드에서 재진입 가능 (재귀 lock)
        Locker locker(isolate);
        Isolate::Scope iso_scope(isolate);
        HandleScope handle_scope(isolate);
        Context::Scope ctx_scope(g_setup->context());

        IpcRequest inline_req;
        inline_req.channel = channel;
        inline_req.data = data;
        execute_ipc_request(isolate, &inline_req);
        return strdup(inline_req.response.c_str());
    }

    // 정상 경로: 외부 스레드에서 Node에 invoke. 큐에 넣고 Node event loop가 처리.
    auto* req = new IpcRequest();
    req->channel = channel;
    req->data = data;

    {
        std::lock_guard<std::mutex> lock(g_ipc_mutex);
        g_ipc_queue.push_back(req);
    }

    // Node 이벤트 루프에 알림
    uv_async_send(&g_ipc_async);

    // 응답 대기 (최대 30초)
    {
        std::unique_lock<std::mutex> lock(req->mtx);
        req->cv.wait_for(lock, std::chrono::seconds(30), [req]() { return req->done; });
    }

    char* result;
    if (req->done) {
        result = strdup(req->response.c_str());
    } else {
        result = strdup("{\"error\":\"node invoke timeout (30s)\"}");
    }
    delete req;
    return result;
}

void suji_node_free(const char* ptr) {
    if (ptr) free(const_cast<char*>(ptr));
}

void suji_node_set_handler(suji_node_handler_fn handler) {
    (void)handler;
}

void suji_node_set_core(struct SujiNodeCore core) {
    g_core = core;
    fprintf(stderr, "[suji-node] core connected (invoke/send/register)\n");
}

} // extern "C"
