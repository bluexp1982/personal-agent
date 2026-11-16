#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "tray_indicator.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  // 主窗口。窗口由 GtkApplication 持有，这里只借用，不做引用计数。
  //
  // 关窗改为"隐藏"之后，这个指针的生命周期不再等于进程生命周期：窗口可以
  // 一直存在但不可见，只有托盘的「退出」才会真的销毁它（见 `destroy` 回调）。
  GtkWindow* window;

  // 状态栏图标。为 nullptr 表示没建起来，此时关窗退回"直接退出"。
  TrayIndicator* tray;

  // 与 Dart 侧通信的窗口通道（`lib/src/core/window_chrome.dart`）。
  // macOS / Windows 用同一个名字，Dart 侧因此不必分平台。
  FlMethodChannel* window_channel;

  // 当前是否处于窗口管理器给的全屏状态。
  //
  // GTK3 没有 `gtk_window_is_fullscreen()`，状态只能自己跟：进入/退出都只发
  // 请求，真正的结果由 `window-state-event` 告诉我们（WM 可能拒绝，例如
  // 某些平铺式窗口管理器）。
  gboolean is_full_screen;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// 把全屏状态变化回传给 Dart：用户在 WM 层退出全屏（快捷键、把窗口拖出全屏）
// 时，界面必须跟着退出沉浸模式，否则会停在"窗口还原了、界面还满屏"。
static void notify_full_screen_changed(MyApplication* self) {
  if (self->window_channel == nullptr) {
    return;
  }
  g_autoptr(FlValue) arguments = fl_value_new_map();
  fl_value_set_string_take(arguments, "fullScreen",
                           fl_value_new_bool(self->is_full_screen));
  fl_method_channel_invoke_method(self->window_channel, "fullScreenChanged",
                                  arguments, nullptr, nullptr, nullptr);
}

// 跟踪 `GDK_WINDOW_STATE_FULLSCREEN`，并把它同步给 Dart。
static gboolean window_state_event_cb(GtkWidget* widget,
                                      GdkEventWindowState* event,
                                      gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gboolean is_full_screen =
      (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
  if (is_full_screen != self->is_full_screen) {
    self->is_full_screen = is_full_screen;
    notify_full_screen_changed(self);
  }
  // 不吞事件：窗口管理器与 GTK 自己的布局仍要看到它。
  return FALSE;
}

// 处理 `personal_agent/window` 上的调用。
static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "isFullScreen") == 0) {
    g_autoptr(FlValue) result = fl_value_new_bool(self->is_full_screen);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "setFullScreen") == 0) {
    gboolean target = self->is_full_screen;
    FlValue* arguments = fl_method_call_get_args(method_call);
    if (arguments != nullptr && fl_value_get_type(arguments) == FL_VALUE_TYPE_MAP) {
      FlValue* value = fl_value_lookup_string(arguments, "fullScreen");
      if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
        target = fl_value_get_bool(value);
      }
    }
    if (self->window != nullptr && target != self->is_full_screen) {
      if (target) {
        gtk_window_fullscreen(self->window);
      } else {
        gtk_window_unfullscreen(self->window);
      }
      // 这里只发请求；真正的状态由 `window-state-event` 回填并通知 Dart。
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// 托盘菜单「显示主窗口」。
static void show_window_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window == nullptr) {
    return;
  }
  // `present` 对隐藏窗口会顺带 show 一次，还会把窗口提到最前并把焦点给它。
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_present(self->window);
}

// 真正的退出动作，排到主循环里执行。
static gboolean quit_in_idle(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window != nullptr) {
    // 销毁窗口 → GtkApplication 的窗口列表清空 → 进程自然退出。
    gtk_widget_destroy(GTK_WIDGET(self->window));
  }
  g_application_quit(G_APPLICATION(self));
  return G_SOURCE_REMOVE;
}

// 托盘菜单「退出 Jarvis」。
static void quit_app_cb(gpointer user_data) {
  // 不能在这个 `activate` 回调里直接销毁菜单自己（`tray_indicator_free`
  // 会 destroy 掉正在派发信号的那个 GtkMenu）。排到主循环末尾再退。
  g_idle_add(quit_in_idle, user_data);
}

// 窗口真被销毁时清指针并撤掉图标。
//
// `window` 只是借用，窗口销毁后必须置空：否则下次 `activate`（单实例下
// 第二次启动会走到那里）会去 present 一个已释放的对象。
static void window_destroy_cb(GtkWidget* widget, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (GTK_WIDGET(self->window) == widget) {
    self->window = nullptr;
  }
  if (self->tray != nullptr) {
    tray_indicator_free(self->tray);
    self->tray = nullptr;
  }
}

// 关窗 = 收进状态栏。
//
// 状态栏图标没建起来时必须返回 FALSE（走默认的销毁流程），保留"关窗即
// 退出"的旧行为：否则窗口藏了、图标也没有，用户只能去杀进程。
static gboolean window_delete_event_cb(GtkWidget* widget, GdkEvent* event,
                                       gpointer user_data) {
  (void)event;
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->tray == nullptr) {
    return FALSE;
  }
  gtk_widget_hide(widget);
  return TRUE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // 单实例下第二次启动会被 D-Bus 转发到这里，此时窗口已经存在（可能正
  // 藏在状态栏里）：唤回它，不再造第二扇窗、第二个引擎。
  if (self->window != nullptr) {
    gtk_widget_show(GTK_WIDGET(self->window));
    gtk_window_present(self->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // 关窗 = 收起，不销毁；真正的销毁只发生在托盘的「退出」。
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event_cb),
                   self);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroy_cb), self);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Jarvis");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Jarvis");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // 窗口下限：390 × 600 逻辑像素（GTK3 / GDK 的几何提示按应用逻辑像素算，
  // 不需要像 Windows 那样按 HiDPI 缩放）。
  //
  // 390 是 iPhone 13 的视口宽度，也是窄屏单列布局（< 700 断点）能完整放下
  // 内容的最小宽度：再窄卡片右侧就会溢出。高度取 600 而不是 iPhone 13 的
  // 844——默认窗口一直是 1280 × 720，844 的下限会让"首次拖边"变成"窗口突然
  // 长高"。
  //
  // 同一条下限另外两端各存一份（macOS `MainFlutterWindow.contentMinSize`、
  // Windows `win32_window.cpp` 的 `WM_GETMINMAXINFO`）：原生读不到 Dart 常量，
  // 改动时三处一起改。几何提示约束的是 toplevel 本身，GNOME 的 CSD 头部也
  // 算在这 600 里，所以内容区会比另两端略矮几十像素；高度只是"不低于手机
  // 视口"的兜底，窄屏布局本来就能纵向滚动，不影响可用性。
  GdkGeometry geometry;
  geometry.min_width = 390;
  geometry.min_height = 600;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

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

  // 窗口全屏通道：与 macOS / Windows 同名同协议，Dart 侧只有一套调用。
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel =
      fl_method_channel_new(messenger, "personal_agent/window",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);

  // `window-state-event` 需要显式订阅结构变化，否则收不到全屏状态。
  gtk_widget_add_events(GTK_WIDGET(window), GDK_STRUCTURE_MASK);
  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(window_state_event_cb), self);

  gtk_widget_grab_focus(GTK_WIDGET(view));

  // 状态栏图标：窗口隐藏之后唯一的入口。
  //
  // 放在窗口与引擎都就绪之后：图标一点就要能 present 窗口，提前建出来的话
  // 第一条菜单命令会落在一个半成品上。
  TrayIndicatorCallbacks callbacks;
  callbacks.show_window = show_window_cb;
  callbacks.quit_app = quit_app_cb;
  callbacks.user_data = self;
  self->tray = tray_indicator_new(&callbacks);
  if (self->tray == nullptr) {
    // 退回"关窗即退出"（见 `window_delete_event_cb`），不要出现"窗口藏了、
    // 图标也没有"的死状态。
    g_warning("状态栏图标不可用：关闭窗口将直接退出");
  }
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
  // 窗口由 GtkApplication 持有，这里只松开借用；通道与状态栏图标是自己建的，
  // 要清掉。
  self->window = nullptr;
  if (self->tray != nullptr) {
    tray_indicator_free(self->tray);
    self->tray = nullptr;
  }
  g_clear_object(&self->window_channel);
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

static void my_application_init(MyApplication* self) {
  // g_object_new 会把实例内存清零，这里写出来只为让"未进入全屏"这件事显式。
  self->window = nullptr;
  self->tray = nullptr;
  self->window_channel = nullptr;
  self->is_full_screen = FALSE;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

#ifdef NDEBUG
  // 发布版：单实例。窗口收进状态栏之后没有任务栏按钮，"再点一次应用图标"
  // 只会被 D-Bus 转发到已运行的实例（见 `my_application_activate` 的复用分支），
  // 不会多起一份引擎与连接。
  const GApplicationFlags flags = static_cast<GApplicationFlags>(0);
#else
  // 开发版保持非唯一：`flutter run` 每次都要能真的跑起新构建，不能被已在
  // 运行的那一份"复用"掉——那种表现看起来像"改了没生效"。
  //
  // 用 `static_cast` 而不是 `G_APPLICATION_FLAGS_NONE`：后者在 glib 2.74
  // 起标了 deprecated，而 runner 带着 `-Wall -Werror`。
  const GApplicationFlags flags = G_APPLICATION_NON_UNIQUE;
#endif

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
