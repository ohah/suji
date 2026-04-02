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
static std::thread g_thread;

// IPC 핸들러 맵 (channel → JS function)
static std::unordered_map<std::string, Global<Function>> g_handlers;
static std::mutex g_handler_mutex;

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
        std::string result = "{\"error\":\"no handler\"}";

        {
            std::lock_guard<std::mutex> lock(g_handler_mutex);
            auto it = g_handlers.find(req->channel);
            if (it != g_handlers.end()) {
                Local<Function> fn = it->second.Get(isolate);
                Local<String> arg = String::NewFromUtf8(isolate, req->data.c_str()).ToLocalChecked();
                Local<Value> argv[1] = { arg };

                v8::TryCatch try_catch(isolate);
                auto maybe_result = fn->Call(g_setup->context(), v8::Undefined(isolate), 1, argv);

                if (!maybe_result.IsEmpty()) {
                    Local<Value> ret = maybe_result.ToLocalChecked();
                    if (ret->IsString()) {
                        String::Utf8Value utf8(isolate, ret);
                        result = std::string(*utf8, utf8.length());
                    } else {
                        // JSON.stringify
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
                    result = std::string("{\"error\":\"") + *err + "\"}";
                }
            }
        }

        {
            std::lock_guard<std::mutex> lock(req->mtx);
            req->response = std::move(result);
            req->done = true;
        }
        req->cv.notify_one();
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

        // globalThis.__suji_handle 등록
        Local<v8::FunctionTemplate> handle_tmpl = v8::FunctionTemplate::New(isolate, js_suji_handle);
        g_setup->context()->Global()->Set(
            g_setup->context(),
            String::NewFromUtf8(isolate, "__suji_handle").ToLocalChecked(),
            handle_tmpl->GetFunction(g_setup->context()).ToLocalChecked()
        ).Check();

        // 엔트리 JS 파일 로드 — @suji/node SDK를 주입하고 사용자 코드 실행
        std::string code = std::string(
            "globalThis.suji = { handle: __suji_handle };"
            "const { createRequire } = require('module');"
            "const r = createRequire('") + entry_path + "');"
            "r('" + entry_path + "');";

        auto load_result = node::LoadEnvironment(env, code.c_str());

        if (load_result.IsEmpty()) {
            fprintf(stderr, "[suji-node] failed to load: %s\n", entry_path);
            return -1;
        }

        g_running.store(true);
        node::SpinEventLoop(env).FromMaybe(1);
        g_running.store(false);
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
    g_handlers.clear();
    g_setup.reset();
    if (g_initialized.load()) {
        v8::V8::Dispose();
        v8::V8::DisposePlatform();
        g_platform.reset();
        node::TearDownOncePerProcess();
        g_initialized.store(false);
    }
}

const char* suji_node_invoke(const char* channel, const char* data) {
    if (!g_running.load()) return strdup("{\"error\":\"node not running\"}");

    // IPC 요청을 큐에 넣고 Node 스레드에서 처리 대기
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

    char* result = strdup(req->response.c_str());
    delete req;
    return result;
}

void suji_node_free(const char* ptr) {
    if (ptr) free(const_cast<char*>(ptr));
}

void suji_node_set_handler(suji_node_handler_fn handler) {
    (void)handler;
}

} // extern "C"
