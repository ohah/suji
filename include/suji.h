/* suji — dlopen backend/plugin C ABI.
 *
 * Backends compiled as shared libraries export backend_init,
 * backend_handle_ipc, backend_free and backend_destroy. Suji injects a
 * SujiCore table during backend_init so the backend can call other backends,
 * emit events, register channels and access the v1 window raw dispatcher.
 *
 * This header is for desktop dlopen backends/plugins. The embeddable mobile
 * core C ABI lives in include/suji_core.h.
 */
#ifndef SUJI_H
#define SUJI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef SUJI_EXPORT
#  if defined(_WIN32)
#    define SUJI_EXPORT __declspec(dllexport)
#  else
#    define SUJI_EXPORT __attribute__((visibility("default")))
#  endif
#endif

typedef struct SujiWindowApi SujiWindowApi;
typedef struct SujiCore SujiCore;

typedef void (*suji_event_callback)(const char *event_name,
                                    const char *data,
                                    void *arg);

/* Window API v1.
 *
 * request_json accepts the same JSON object used by frontend __suji__.core for
 * window/webContents commands, for example:
 *   {"cmd":"set_title","windowId":1,"title":"Hello"}
 *
 * The returned response string is owned by Suji. Call free_response from the
 * same table after copying/consuming it. The table can be NULL when the core
 * has not installed the __core__ dispatcher yet.
 */
struct SujiWindowApi {
    const char *(*request_json)(const char *request_json);
    void (*free_response)(const char *response);
};

/* Core API injected into backend_init. All strings are UTF-8 and null
 * terminated. invoke responses are owned by Suji and must be released with
 * core->free after copying/consuming them.
 */
struct SujiCore {
    const char *(*invoke)(const char *backend, const char *request_json);
    void (*free)(const char *response);
    void (*emit)(const char *event_name, const char *data);
    uint64_t (*on)(const char *event_name, suji_event_callback callback, void *arg);
    void (*off)(uint64_t listener_id);
    void (*register_channel)(const char *channel);
    const void *(*get_io)(void);
    void (*quit)(void);
    const char *(*platform)(void);
    void (*emit_to)(uint32_t window_id, const char *event_name, const char *data);
    const SujiWindowApi *(*get_window_api)(void);
};

static inline const SujiWindowApi *suji_core_window_api(const SujiCore *core) {
    if (!core || !core->get_window_api) return 0;
    return core->get_window_api();
}

static inline const char *suji_window_request_json(const SujiWindowApi *api,
                                                   const char *request_json) {
    if (!api || !api->request_json) return 0;
    return api->request_json(request_json);
}

static inline void suji_window_free_response(const SujiWindowApi *api,
                                             const char *response) {
    if (!api || !api->free_response || !response) return;
    api->free_response(response);
}

/* Symbols looked up by Suji when loading a backend/plugin shared library. */
SUJI_EXPORT void backend_init(const SujiCore *core);
SUJI_EXPORT char *backend_handle_ipc(const char *request_json);
SUJI_EXPORT void backend_free(char *response);
SUJI_EXPORT void backend_destroy(void);

#ifdef __cplusplus
}
#endif

#endif /* SUJI_H */
