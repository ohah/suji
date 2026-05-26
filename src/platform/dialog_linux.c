#include <stddef.h>

typedef void GtkWidget;
typedef void GtkWindow;
typedef void GtkDialog;
typedef void GtkMessageDialog;
typedef int gboolean;
typedef unsigned int guint;
typedef void *gpointer;
typedef gboolean (*GSourceFunc)(gpointer);

enum {
    SUJI_GTK_DIALOG_MODAL = 1 << 0,
    SUJI_GTK_BUTTONS_NONE = 0,
    SUJI_GTK_RESPONSE_CANCEL = -6,
    SUJI_GTK_MESSAGE_INFO = 0,
    SUJI_GTK_FILE_CHOOSER_ACTION_OPEN = 0,
};

extern int gtk_init_check(int *argc, void *argv);
extern GtkWidget *gtk_message_dialog_new(GtkWindow *parent, int flags, int type, int buttons, const char *message_format, ...);
extern void gtk_message_dialog_format_secondary_text(GtkMessageDialog *message_dialog, const char *message_format, ...);
extern GtkWidget *gtk_file_chooser_dialog_new(const char *title, GtkWindow *parent, int action, const char *first_button_text, ...);
extern void gtk_dialog_response(GtkDialog *dialog, int response_id);
extern guint g_timeout_add(guint interval, GSourceFunc function, gpointer data);

int suji_gtk_init_check(void) {
    return gtk_init_check(NULL, NULL);
}

void *suji_gtk_message_dialog_new(int message_type, const char *message) {
    return gtk_message_dialog_new(
        NULL,
        SUJI_GTK_DIALOG_MODAL,
        message_type,
        SUJI_GTK_BUTTONS_NONE,
        "%s",
        message ? message : "");
}

void suji_gtk_message_dialog_set_detail(void *dialog, const char *detail) {
    if (!dialog) return;
    gtk_message_dialog_format_secondary_text((GtkMessageDialog *)dialog, "%s", detail ? detail : "");
}

void *suji_gtk_file_chooser_dialog_new(int action, const char *title, const char *accept_label) {
    return gtk_file_chooser_dialog_new(
        (title && title[0]) ? title : NULL,
        NULL,
        action,
        "_Cancel",
        SUJI_GTK_RESPONSE_CANCEL,
        (accept_label && accept_label[0]) ? accept_label : "_Open",
        -3,
        NULL);
}

static gboolean suji_gtk_auto_cancel(gpointer data) {
    if (data) gtk_dialog_response((GtkDialog *)data, SUJI_GTK_RESPONSE_CANCEL);
    return 0;
}

void suji_gtk_dialog_auto_cancel(void *dialog, guint delay_ms) {
    if (!dialog) return;
    g_timeout_add(delay_ms ? delay_ms : 50, suji_gtk_auto_cancel, dialog);
}
