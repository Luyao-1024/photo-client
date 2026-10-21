#include "my_application.h"

#include <stdio.h>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

struct WindowChannel {
  GtkWindow* window;
  FlMethodChannel* channel;
};

static void window_method_call(FlMethodChannel*, FlMethodCall* call,
                               gpointer user_data) {
  auto* state = static_cast<WindowChannel*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  GtkWindow* window = state->window;
  if (g_str_equal(method, "minimize")) {
    gtk_window_iconify(window);
  } else if (g_str_equal(method, "maximize")) {
    if (gtk_window_is_maximized(window)) gtk_window_unmaximize(window);
    else gtk_window_maximize(window);
  } else if (g_str_equal(method, "fullscreen")) {
    FlValue* args = fl_method_call_get_args(call);
    if (fl_value_get_bool(args)) gtk_window_fullscreen(window);
    else gtk_window_unfullscreen(window);
  } else if (g_str_equal(method, "drag") || g_str_equal(method, "resize")) {
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
    GdkDevice* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(display));
    gint x = 0, y = 0;
    if (pointer) gdk_device_get_position(pointer, nullptr, &x, &y);
    if (g_str_equal(method, "drag")) {
      gtk_window_begin_move_drag(window, 1, x, y, GDK_CURRENT_TIME);
    } else {
      const int edge = static_cast<int>(fl_value_get_int(fl_method_call_get_args(call)));
      if (edge >= 0 && edge <= 7) gtk_window_begin_resize_drag(
          window, static_cast<GdkWindowEdge>(edge), 1, x, y, GDK_CURRENT_TIME);
    }
  } else if (g_str_equal(method, "close")) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    gtk_widget_destroy(GTK_WIDGET(window));
    return;
  } else if (!g_str_equal(method, "state")) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  g_autoptr(FlValue) result = fl_value_new_bool(gtk_window_is_maximized(window));
  fl_method_call_respond_success(call, result, nullptr);
}

static gboolean window_delete(GtkWidget*, GdkEvent*, gpointer user_data) {
  auto* state = static_cast<WindowChannel*>(user_data);
  fl_method_channel_invoke_method(state->channel, "closeRequested", nullptr,
                                 nullptr, nullptr, nullptr);
  return TRUE;  // Dart confirms pending local edits / scans before destruction.
}

static gboolean window_state(GtkWidget*, GdkEventWindowState* event,
                             gpointer user_data) {
  auto* state = static_cast<WindowChannel*>(user_data);
  g_autoptr(FlValue) maximized = fl_value_new_bool(
      (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0);
  fl_method_channel_invoke_method(state->channel, "stateChanged", maximized,
                                 nullptr, nullptr, nullptr);
  return FALSE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Flutter owns all window chrome. Never create a GtkHeaderBar or request
  // compositor decorations (including on non-GNOME window managers).
  gtk_window_set_title(window, "PhotoViewer");
  gtk_window_set_decorated(window, FALSE);
  // Flutter clips the full frame, including its photo backdrop. The native
  // surface must preserve alpha or the clipped corners would remain black.
  GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(window));
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual) gtk_widget_set_visual(GTK_WIDGET(window), visual);
  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  gtk_widget_set_name(GTK_WIDGET(window), "photo-client-window");
  g_autoptr(GtkCssProvider) css = gtk_css_provider_new();
  gtk_css_provider_load_from_data(css,
      "#photo-client-window { background-color: transparent; }", -1, nullptr);
  gtk_style_context_add_provider(gtk_widget_get_style_context(GTK_WIDGET(window)),
      GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  // Deterministic window geometry for responsive/acceptance runs. The flag is
  // also forwarded to Dart, which ignores it.
  gint window_width = 1280;
  gint window_height = 720;
  const gchar kWindowSizeFlag[] = "--window-size=";
  for (gchar** argument = self->dart_entrypoint_arguments; argument && *argument;
       ++argument) {
    if (!g_str_has_prefix(*argument, kWindowSizeFlag)) {
      continue;
    }
    gint parsed_width = 0;
    gint parsed_height = 0;
    if (sscanf(*argument + sizeof(kWindowSizeFlag) - 1, "%dx%d", &parsed_width,
               &parsed_height) == 2 &&
        parsed_width > 0 && parsed_height > 0) {
      window_width = parsed_width;
      window_height = parsed_height;
    }
  }
  gtk_window_set_default_size(window, window_width, window_height);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "photo_client/window", FL_METHOD_CODEC(codec));
  auto* window_channel = new WindowChannel{window, channel};
  fl_method_channel_set_method_call_handler(channel, window_method_call,
                                           window_channel, nullptr);
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete), window_channel);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state), window_channel);
  g_object_set_data_full(G_OBJECT(window), "photo-window-channel", window_channel,
                        [](gpointer data) {
                          auto* state = static_cast<WindowChannel*>(data);
                          g_object_unref(state->channel);
                          delete state;
                        });

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

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
