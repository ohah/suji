// notification_rich_linux.c
//
// Freedesktop Notifications rich action wrapper for
// @suji/plugin-notification-rich. Uses GDBus directly so the plugin can route
// ActionInvoked signals back into Suji without adding a libnotify dependency.

#include <gio/gio.h>
#include <glib.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    guint32 server_id;
    char *app_id;
} SujiRichLiveNotification;

static GDBusConnection *g_bus = NULL;
static guint g_action_sub = 0;
static guint g_closed_sub = 0;
static GMutex g_live_mutex;
static SujiRichLiveNotification g_live[128];
static void (*g_action_callback)(const char *notification_id, const char *action_id) = NULL;

static void remember_mapping(guint32 server_id, const char *app_id) {
    if (!app_id || !*app_id) return;
    g_mutex_lock(&g_live_mutex);
    for (guint i = 0; i < G_N_ELEMENTS(g_live); i++) {
        if (g_live[i].server_id == server_id) {
            g_free(g_live[i].app_id);
            g_live[i].app_id = g_strdup(app_id);
            g_mutex_unlock(&g_live_mutex);
            return;
        }
    }
    for (guint i = 0; i < G_N_ELEMENTS(g_live); i++) {
        if (g_live[i].server_id == 0) {
            g_live[i].server_id = server_id;
            g_live[i].app_id = g_strdup(app_id);
            g_mutex_unlock(&g_live_mutex);
            return;
        }
    }
    g_mutex_unlock(&g_live_mutex);
}

static char *take_app_id_by_server_id(guint32 server_id) {
    char *app_id = NULL;
    g_mutex_lock(&g_live_mutex);
    for (guint i = 0; i < G_N_ELEMENTS(g_live); i++) {
        if (g_live[i].server_id == server_id) {
            app_id = g_live[i].app_id;
            g_live[i].app_id = NULL;
            g_live[i].server_id = 0;
            break;
        }
    }
    g_mutex_unlock(&g_live_mutex);
    return app_id;
}

static guint32 find_server_id_by_app_id(const char *app_id) {
    guint32 server_id = 0;
    if (!app_id) return 0;
    g_mutex_lock(&g_live_mutex);
    for (guint i = 0; i < G_N_ELEMENTS(g_live); i++) {
        if (g_live[i].server_id != 0 && g_live[i].app_id && strcmp(g_live[i].app_id, app_id) == 0) {
            server_id = g_live[i].server_id;
            break;
        }
    }
    g_mutex_unlock(&g_live_mutex);
    return server_id;
}

static void remove_mapping_by_app_id(const char *app_id) {
    if (!app_id) return;
    g_mutex_lock(&g_live_mutex);
    for (guint i = 0; i < G_N_ELEMENTS(g_live); i++) {
        if (g_live[i].server_id != 0 && g_live[i].app_id && strcmp(g_live[i].app_id, app_id) == 0) {
            g_free(g_live[i].app_id);
            g_live[i].app_id = NULL;
            g_live[i].server_id = 0;
            break;
        }
    }
    g_mutex_unlock(&g_live_mutex);
}

static void action_signal_cb(
    GDBusConnection *connection,
    const gchar *sender_name,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *signal_name,
    GVariant *parameters,
    gpointer user_data
) {
    (void)connection;
    (void)sender_name;
    (void)object_path;
    (void)interface_name;
    (void)signal_name;
    (void)user_data;

    guint32 server_id = 0;
    const gchar *action_key = NULL;
    g_variant_get(parameters, "(u&s)", &server_id, &action_key);
    char *app_id = take_app_id_by_server_id(server_id);
    if (app_id && action_key && g_action_callback) {
        g_action_callback(app_id, action_key);
    }
    g_free(app_id);
}

static void closed_signal_cb(
    GDBusConnection *connection,
    const gchar *sender_name,
    const gchar *object_path,
    const gchar *interface_name,
    const gchar *signal_name,
    GVariant *parameters,
    gpointer user_data
) {
    (void)connection;
    (void)sender_name;
    (void)object_path;
    (void)interface_name;
    (void)signal_name;
    (void)user_data;

    guint32 server_id = 0;
    guint32 reason = 0;
    g_variant_get(parameters, "(uu)", &server_id, &reason);
    char *app_id = take_app_id_by_server_id(server_id);
    g_free(app_id);
}

static int ensure_bus(void) {
    if (g_bus) return 1;
    GError *error = NULL;
    g_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (error) g_error_free(error);
    if (!g_bus) return 0;

    g_action_sub = g_dbus_connection_signal_subscribe(
        g_bus,
        "org.freedesktop.Notifications",
        "org.freedesktop.Notifications",
        "ActionInvoked",
        "/org/freedesktop/Notifications",
        NULL,
        G_DBUS_SIGNAL_FLAGS_NONE,
        action_signal_cb,
        NULL,
        NULL
    );
    g_closed_sub = g_dbus_connection_signal_subscribe(
        g_bus,
        "org.freedesktop.Notifications",
        "org.freedesktop.Notifications",
        "NotificationClosed",
        "/org/freedesktop/Notifications",
        NULL,
        G_DBUS_SIGNAL_FLAGS_NONE,
        closed_signal_cb,
        NULL,
        NULL
    );
    return g_action_sub != 0 && g_closed_sub != 0;
}

void suji_notification_rich_linux_set_action_callback(void (*cb)(const char *, const char *)) {
    g_action_callback = cb;
    (void)ensure_bus();
}

int suji_notification_rich_linux_show(
    const char *id,
    const char *title,
    const char *body,
    const char *image_path,
    int silent,
    const char * const *action_ids,
    const char * const *action_labels,
    int action_count
) {
    if (!id || !title || !body) return 0;
    if (!ensure_bus()) return 0;

    GVariantBuilder actions;
    g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
    for (int i = 0; i < action_count; i++) {
        if (!action_ids || !action_labels || !action_ids[i] || !action_labels[i]) continue;
        g_variant_builder_add(&actions, "s", action_ids[i]);
        g_variant_builder_add(&actions, "s", action_labels[i]);
    }

    GVariantBuilder hints;
    g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
    if (silent) {
        g_variant_builder_add(&hints, "{sv}", "suppress-sound", g_variant_new_boolean(TRUE));
    }
    if (image_path && image_path[0]) {
        g_variant_builder_add(&hints, "{sv}", "image-path", g_variant_new_string(image_path));
    }

    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_sync(
        g_bus,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        g_variant_new(
            "(susssasa{sv}i)",
            "Suji",
            (guint32)0,
            (image_path && image_path[0]) ? image_path : "",
            title,
            body,
            &actions,
            &hints,
            -1
        ),
        G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE,
        -1,
        NULL,
        &error
    );
    if (error) {
        g_error_free(error);
        return 0;
    }
    if (!result) return 0;

    guint32 server_id = 0;
    g_variant_get(result, "(u)", &server_id);
    g_variant_unref(result);
    if (server_id == 0) return 0;
    remember_mapping(server_id, id);
    return 1;
}

void suji_notification_rich_linux_hide(const char *id) {
    if (!id || !ensure_bus()) return;
    guint32 server_id = find_server_id_by_app_id(id);
    if (server_id == 0) return;
    (void)g_dbus_connection_call_sync(
        g_bus,
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "CloseNotification",
        g_variant_new("(u)", server_id),
        NULL,
        G_DBUS_CALL_FLAGS_NONE,
        -1,
        NULL,
        NULL
    );
    remove_mapping_by_app_id(id);
}
