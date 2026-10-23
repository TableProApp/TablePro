#include <gtk/gtk.h>
#include <stdio.h>

static guint labels_alive;
static guint contexts_alive;
static guint children_alive;

static void retired(gpointer data, GObject *object) {
    (void)object;
    guint *count = data;
    g_assert_cmpuint(*count, >, 0);
    --*count;
}

static void observe(GObject *object, guint *count) {
    ++*count;
    g_object_weak_ref(object, retired, count);
}

static void drain(gint milliseconds) {
    gint64 until = g_get_monotonic_time() + milliseconds * 1000;
    do {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    } while (g_get_monotonic_time() < until);
}

int main(void) {
    gtk_init();
    GtkWidget *window = gtk_window_new();
    GtkWidget *notebook = gtk_notebook_new();
    gtk_window_set_child(GTK_WINDOW(window), notebook);
    gtk_window_set_default_size(GTK_WINDOW(window), 640, 480);
    gtk_window_present(GTK_WINDOW(window));
    drain(200);
    printf("{\"cycles\":[");
    for (guint cycle = 0; cycle < 5; ++cycle) {
        for (guint page = 0; page < 50; ++page) {
            GtkWidget *child = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
            GtkWidget *label = gtk_label_new("Rows 1-5000");
            g_object_ref_sink(label);
            observe(G_OBJECT(child), &children_alive);
            observe(G_OBJECT(label), &labels_alive);
            gtk_notebook_append_page(GTK_NOTEBOOK(notebook), child, label);
            g_object_unref(label);
            GtkATContext *context = gtk_accessible_get_at_context(GTK_ACCESSIBLE(label));
            if (context) {
                observe(G_OBJECT(context), &contexts_alive);
                g_object_unref(context);
            }
            if (gtk_notebook_get_n_pages(GTK_NOTEBOOK(notebook)) > 4)
                gtk_notebook_remove_page(GTK_NOTEBOOK(notebook), 0);
            drain(1);
        }
        while (gtk_notebook_get_n_pages(GTK_NOTEBOOK(notebook)))
            gtk_notebook_remove_page(GTK_NOTEBOOK(notebook), 0);
        drain(500);
        printf("%s{\"cycle\":%u,\"labels_alive\":%u,\"contexts_alive\":%u,\"children_alive\":%u}",
               cycle ? "," : "", cycle + 1, labels_alive, contexts_alive, children_alive);
        fflush(stdout);
    }
    gtk_window_destroy(GTK_WINDOW(window));
    drain(500);
    printf("],\"after_window_destroy\":{\"labels_alive\":%u,\"contexts_alive\":%u,\"children_alive\":%u}}\n",
           labels_alive, contexts_alive, children_alive);
    return labels_alive || contexts_alive || children_alive ? 1 : 0;
}
