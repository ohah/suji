// Linux powerMonitor event bridge.
//
// Runtime sources:
//   - org.freedesktop.login1.Manager.PrepareForSleep(bool) on the system bus
//     true -> suspend, false -> resume
//   - org.freedesktop.ScreenSaver / org.gnome.ScreenSaver ActiveChanged(bool)
//     true -> lock-screen, false -> unlock-screen
//   - org.freedesktop.login1.Session Lock/Unlock as an additional lock source
//
// libdbus is loaded with dlopen so the core keeps building on systems that only
// have the runtime library available, and gracefully becomes a no-op otherwise.

#if defined(__linux__)

#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

typedef int dbus_bool_t;
typedef int DBusBusType;
typedef struct DBusConnection DBusConnection;
typedef struct DBusMessage DBusMessage;
typedef struct DBusError {
    const char *name;
    const char *message;
    unsigned int dummy1 : 1;
    unsigned int dummy2 : 1;
    unsigned int dummy3 : 1;
    unsigned int dummy4 : 1;
    unsigned int dummy5 : 1;
    void *padding1;
} DBusError;

enum {
    DBUS_BUS_SESSION = 0,
    DBUS_BUS_SYSTEM = 1,
    DBUS_TYPE_INVALID = 0,
    DBUS_TYPE_BOOLEAN = 'b',
};

typedef void (*suji_power_cb)(const char *event);

typedef void (*dbus_error_init_fn)(DBusError *);
typedef dbus_bool_t (*dbus_error_is_set_fn)(const DBusError *);
typedef void (*dbus_error_free_fn)(DBusError *);
typedef DBusConnection *(*dbus_bus_get_private_fn)(DBusBusType, DBusError *);
typedef void (*dbus_bus_add_match_fn)(DBusConnection *, const char *, DBusError *);
typedef void (*dbus_connection_set_exit_on_disconnect_fn)(DBusConnection *, dbus_bool_t);
typedef dbus_bool_t (*dbus_connection_read_write_fn)(DBusConnection *, int);
typedef DBusMessage *(*dbus_connection_pop_message_fn)(DBusConnection *);
typedef dbus_bool_t (*dbus_message_is_signal_fn)(DBusMessage *, const char *, const char *);
typedef dbus_bool_t (*dbus_message_get_args_fn)(DBusMessage *, DBusError *, int, ...);
typedef void (*dbus_message_unref_fn)(DBusMessage *);
typedef void (*dbus_connection_close_fn)(DBusConnection *);
typedef void (*dbus_connection_unref_fn)(DBusConnection *);

typedef struct SujiDbus {
    void *lib;
    dbus_error_init_fn error_init;
    dbus_error_is_set_fn error_is_set;
    dbus_error_free_fn error_free;
    dbus_bus_get_private_fn bus_get_private;
    dbus_bus_add_match_fn bus_add_match;
    dbus_connection_set_exit_on_disconnect_fn set_exit_on_disconnect;
    dbus_connection_read_write_fn read_write;
    dbus_connection_pop_message_fn pop_message;
    dbus_message_is_signal_fn message_is_signal;
    dbus_message_get_args_fn message_get_args;
    dbus_message_unref_fn message_unref;
    dbus_connection_close_fn connection_close;
    dbus_connection_unref_fn connection_unref;
} SujiDbus;

static suji_power_cb g_callback = NULL;
static pthread_t g_thread;
static atomic_int g_running = 0;
static atomic_int g_thread_started = 0;

static int load_sym(void *lib, const char *name, void **out) {
    *out = dlsym(lib, name);
    return *out != NULL;
}

static int suji_dbus_load(SujiDbus *d) {
    memset(d, 0, sizeof(*d));
    d->lib = dlopen("libdbus-1.so.3", RTLD_LAZY | RTLD_LOCAL);
    if (!d->lib) return 0;

    if (!load_sym(d->lib, "dbus_error_init", (void **)&d->error_init) ||
        !load_sym(d->lib, "dbus_error_is_set", (void **)&d->error_is_set) ||
        !load_sym(d->lib, "dbus_error_free", (void **)&d->error_free) ||
        !load_sym(d->lib, "dbus_bus_get_private", (void **)&d->bus_get_private) ||
        !load_sym(d->lib, "dbus_bus_add_match", (void **)&d->bus_add_match) ||
        !load_sym(d->lib, "dbus_connection_set_exit_on_disconnect", (void **)&d->set_exit_on_disconnect) ||
        !load_sym(d->lib, "dbus_connection_read_write", (void **)&d->read_write) ||
        !load_sym(d->lib, "dbus_connection_pop_message", (void **)&d->pop_message) ||
        !load_sym(d->lib, "dbus_message_is_signal", (void **)&d->message_is_signal) ||
        !load_sym(d->lib, "dbus_message_get_args", (void **)&d->message_get_args) ||
        !load_sym(d->lib, "dbus_message_unref", (void **)&d->message_unref) ||
        !load_sym(d->lib, "dbus_connection_close", (void **)&d->connection_close) ||
        !load_sym(d->lib, "dbus_connection_unref", (void **)&d->connection_unref)) {
        dlclose(d->lib);
        memset(d, 0, sizeof(*d));
        return 0;
    }
    return 1;
}

static void suji_dbus_unload(SujiDbus *d) {
    if (d->lib) dlclose(d->lib);
    memset(d, 0, sizeof(*d));
}

static void emit_event(const char *event) {
    suji_power_cb cb = g_callback;
    if (cb) cb(event);
}

static void clear_error(SujiDbus *d, DBusError *err) {
    if (d->error_is_set(err)) d->error_free(err);
}

static DBusConnection *open_bus(SujiDbus *d, DBusBusType type) {
    DBusError err;
    d->error_init(&err);
    DBusConnection *conn = d->bus_get_private(type, &err);
    clear_error(d, &err);
    if (conn) d->set_exit_on_disconnect(conn, 0);
    return conn;
}

static void add_match(SujiDbus *d, DBusConnection *conn, const char *rule) {
    if (!conn) return;
    DBusError err;
    d->error_init(&err);
    d->bus_add_match(conn, rule, &err);
    clear_error(d, &err);
}

static int get_bool_arg(SujiDbus *d, DBusMessage *msg, int *value) {
    DBusError err;
    dbus_bool_t active = 0;
    d->error_init(&err);
    dbus_bool_t ok = d->message_get_args(
        msg,
        &err,
        DBUS_TYPE_BOOLEAN,
        &active,
        DBUS_TYPE_INVALID
    );
    clear_error(d, &err);
    if (!ok) return 0;
    *value = active ? 1 : 0;
    return 1;
}

static void process_message(SujiDbus *d, DBusMessage *msg) {
    if (d->message_is_signal(msg, "org.freedesktop.login1.Manager", "PrepareForSleep")) {
        int sleeping = 0;
        if (get_bool_arg(d, msg, &sleeping)) emit_event(sleeping ? "suspend" : "resume");
    } else if (d->message_is_signal(msg, "org.freedesktop.ScreenSaver", "ActiveChanged") ||
               d->message_is_signal(msg, "org.gnome.ScreenSaver", "ActiveChanged")) {
        int active = 0;
        if (get_bool_arg(d, msg, &active)) emit_event(active ? "lock-screen" : "unlock-screen");
    } else if (d->message_is_signal(msg, "org.freedesktop.login1.Session", "Lock")) {
        emit_event("lock-screen");
    } else if (d->message_is_signal(msg, "org.freedesktop.login1.Session", "Unlock")) {
        emit_event("unlock-screen");
    }
}

static void process_bus(SujiDbus *d, DBusConnection *conn) {
    if (!conn) return;
    (void)d->read_write(conn, 100);
    for (;;) {
        DBusMessage *msg = d->pop_message(conn);
        if (!msg) break;
        process_message(d, msg);
        d->message_unref(msg);
    }
}

static void close_bus(SujiDbus *d, DBusConnection *conn) {
    if (!conn) return;
    d->connection_close(conn);
    d->connection_unref(conn);
}

static void *power_thread_main(void *unused) {
    (void)unused;
    SujiDbus d;
    if (!suji_dbus_load(&d)) {
        atomic_store(&g_thread_started, 0);
        atomic_store(&g_running, 0);
        return NULL;
    }

    DBusConnection *system = open_bus(&d, DBUS_BUS_SYSTEM);
    DBusConnection *session = open_bus(&d, DBUS_BUS_SESSION);

    add_match(&d, system,
        "type='signal',interface='org.freedesktop.login1.Manager',"
        "member='PrepareForSleep',path='/org/freedesktop/login1'");
    add_match(&d, system,
        "type='signal',interface='org.freedesktop.login1.Session',member='Lock'");
    add_match(&d, system,
        "type='signal',interface='org.freedesktop.login1.Session',member='Unlock'");
    add_match(&d, session,
        "type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'");
    add_match(&d, session,
        "type='signal',interface='org.gnome.ScreenSaver',member='ActiveChanged'");

    while (atomic_load(&g_running)) {
        process_bus(&d, system);
        process_bus(&d, session);
        if (!system && !session) usleep(200000);
    }

    close_bus(&d, system);
    close_bus(&d, session);
    suji_dbus_unload(&d);
    atomic_store(&g_thread_started, 0);
    return NULL;
}

void suji_power_monitor_linux_install(void (*cb)(const char *event)) {
    g_callback = cb;
    if (atomic_load(&g_running)) return;
    atomic_store(&g_running, 1);
    if (pthread_create(&g_thread, NULL, power_thread_main, NULL) == 0) {
        atomic_store(&g_thread_started, 1);
    } else {
        atomic_store(&g_running, 0);
        atomic_store(&g_thread_started, 0);
    }
}

void suji_power_monitor_linux_uninstall(void) {
    if (!atomic_load(&g_running)) {
        g_callback = NULL;
        return;
    }
    atomic_store(&g_running, 0);
    if (atomic_load(&g_thread_started)) {
        pthread_join(g_thread, NULL);
    }
    g_callback = NULL;
}

#endif
