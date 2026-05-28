#include "suji.h"

#include <stddef.h>

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define SUJI_STATIC_ASSERT _Static_assert
#else
#define SUJI_STATIC_ASSERT(cond, msg) typedef char suji_static_assertion_##__LINE__[(cond) ? 1 : -1]
#endif

SUJI_STATIC_ASSERT(offsetof(SujiWindowApi, request_json) == 0,
                   "request_json must be first");
SUJI_STATIC_ASSERT(offsetof(SujiCore, invoke) == 0,
                   "invoke must be first");

static const char *smoke_invoke(const char *backend, const char *request_json) {
    (void)backend;
    return request_json;
}

static void smoke_free(const char *response) {
    (void)response;
}

static void smoke_emit(const char *event_name, const char *data) {
    (void)event_name;
    (void)data;
}

static uint64_t smoke_on(const char *event_name, suji_event_callback callback, void *arg) {
    if (callback) callback(event_name, "{}", arg);
    return 1;
}

static void smoke_off(uint64_t listener_id) {
    (void)listener_id;
}

static void smoke_register(const char *channel) {
    (void)channel;
}

static const void *smoke_get_io(void) {
    return 0;
}

static void smoke_quit(void) {}

static const char *smoke_platform(void) {
    return "test";
}

static void smoke_emit_to(uint32_t window_id, const char *event_name, const char *data) {
    (void)window_id;
    (void)event_name;
    (void)data;
}

static const char *smoke_window_request(const char *request_json) {
    return request_json;
}

static void smoke_window_free(const char *response) {
    (void)response;
}

static const SujiWindowApi smoke_window_api = {
    smoke_window_request,
    smoke_window_free,
};

static const SujiWindowApi *smoke_get_window_api(void) {
    return &smoke_window_api;
}

static void smoke_event(const char *event_name, const char *data, void *arg) {
    (void)event_name;
    (void)data;
    (void)arg;
}

int suji_header_smoke(void) {
    const SujiCore core = {
        smoke_invoke,
        smoke_free,
        smoke_emit,
        smoke_on,
        smoke_off,
        smoke_register,
        smoke_get_io,
        smoke_quit,
        smoke_platform,
        smoke_emit_to,
        smoke_get_window_api,
    };
    const SujiWindowApi *api = suji_core_window_api(&core);
    const char *response = suji_window_request_json(api, "{\"cmd\":\"get_url\",\"windowId\":1}");
    suji_window_free_response(api, response);
    return core.on("ready", smoke_event, 0) == 1 ? 0 : 1;
}

SUJI_EXPORT void backend_init(const SujiCore *core) {
    (void)core;
}

SUJI_EXPORT char *backend_handle_ipc(const char *request_json) {
    (void)request_json;
    return 0;
}

SUJI_EXPORT void backend_free(char *response) {
    (void)response;
}

SUJI_EXPORT void backend_destroy(void) {}
