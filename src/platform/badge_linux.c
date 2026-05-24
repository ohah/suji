// Linux app badge count bridge.
//
// Unity-style launcher badges are provided by libunity. It is optional on many
// desktops, so this bridge uses dlopen and returns 0 when unavailable.

#if defined(__linux__)

#include <dlfcn.h>
#include <stdint.h>

typedef void *(*unity_get_for_desktop_id_fn)(const char *desktop_id);
typedef void (*unity_set_count_fn)(void *entry, int64_t count);
typedef void (*unity_set_count_visible_fn)(void *entry, int visible);

static void *open_libunity(void) {
    void *lib = dlopen("libunity.so.9", RTLD_LAZY | RTLD_LOCAL);
    if (lib) return lib;
    return dlopen("libunity.so", RTLD_LAZY | RTLD_LOCAL);
}

int suji_linux_badge_set_count(const char *desktop_id, uint32_t count) {
    void *lib = open_libunity();
    if (!lib) return 0;

    unity_get_for_desktop_id_fn get_for_desktop_id =
        (unity_get_for_desktop_id_fn)dlsym(lib, "unity_launcher_entry_get_for_desktop_id");
    unity_set_count_fn set_count =
        (unity_set_count_fn)dlsym(lib, "unity_launcher_entry_set_count");
    unity_set_count_visible_fn set_count_visible =
        (unity_set_count_visible_fn)dlsym(lib, "unity_launcher_entry_set_count_visible");

    if (!get_for_desktop_id || !set_count || !set_count_visible) {
        dlclose(lib);
        return 0;
    }

    const char *id = (desktop_id && desktop_id[0]) ? desktop_id : "suji.desktop";
    void *entry = get_for_desktop_id(id);
    if (!entry) {
        dlclose(lib);
        return 0;
    }

    set_count(entry, (int64_t)count);
    set_count_visible(entry, count > 0 ? 1 : 0);
    dlclose(lib);
    return 1;
}

#else

#include <stdint.h>

int suji_linux_badge_set_count(const char *desktop_id, uint32_t count) {
    (void)desktop_id;
    (void)count;
    return 0;
}

#endif
