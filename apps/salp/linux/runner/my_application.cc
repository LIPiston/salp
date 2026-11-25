#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* lock_channel;
  GDBusConnection* lock_bus;
  guint lock_subscription;
  guint gnome_lock_subscription;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// ScreenSaver ActiveChanged is emitted by GNOME/KDE/freedesktop lockers.
// Sender is matched through its well-known bus name; arbitrary peers cannot
// impersonate it via a signal path alone.
static void screensaver_changed(GDBusConnection*, const gchar*, const gchar*,
                                const gchar*, const gchar*, GVariant* parameters,
                                gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  gboolean active = FALSE;
  if (g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) {
    g_variant_get(parameters, "(b)", &active);
    if (self->lock_channel) {
      fl_method_channel_invoke_method(self->lock_channel, active ? "lock" : "unlock", nullptr,
                                      nullptr, nullptr, nullptr);
    }
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 720);

  // If you want to use a header bar, uncomment the following lines.
  // Header bars are commonly used in GNOME based desktop environments and
  // allow additional widgets to be added to the title bar.
  // See https://docs.gtk.org/gtk3/class.HeaderBar.html
  // GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  // gtk_widget_show(GTK_WIDGET(header_bar));
  // gtk_header_bar_set_show_close_button(header_bar, TRUE);
  // gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));

  gtk_window_set_title(window, "salp");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlStandardMethodCodec) lock_codec = fl_standard_method_codec_new();
  self->lock_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "dev.salp/session-lock", FL_METHOD_CODEC(lock_codec));
  self->lock_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (self->lock_bus) {
    self->lock_subscription = g_dbus_connection_signal_subscribe(
        self->lock_bus, "org.freedesktop.ScreenSaver", "org.freedesktop.ScreenSaver",
        "ActiveChanged", nullptr, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        screensaver_changed, self, nullptr);
    // Some GNOME sessions expose only their namespaced service.
    self->gnome_lock_subscription = g_dbus_connection_signal_subscribe(
        self->lock_bus, "org.gnome.ScreenSaver", "org.gnome.ScreenSaver",
        "ActiveChanged", nullptr, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        screensaver_changed, self, nullptr);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  if (self->lock_bus && self->lock_subscription) {
    g_dbus_connection_signal_unsubscribe(self->lock_bus, self->lock_subscription);
  }
  if (self->lock_bus && self->gnome_lock_subscription) {
    g_dbus_connection_signal_unsubscribe(self->lock_bus, self->gnome_lock_subscription);
  }
  g_clear_object(&self->lock_channel);
  g_clear_object(&self->lock_bus);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
