#include "tray_indicator.h"

#ifdef HAVE_AYATANA_APPINDICATOR
#include <libayatana-appindicator/app-indicator.h>
#endif

struct _TrayIndicator {
  TrayIndicatorCallbacks callbacks;

  // 菜单由两条实现共用；`show_item` 留着是为了后续要按窗口状态改文案。
  GtkWidget* menu;
  GtkWidget* show_item;

#ifdef HAVE_AYATANA_APPINDICATOR
  AppIndicator* indicator;
#else
  GtkStatusIcon* icon;
#endif
};

namespace {

// 用哪个图标文件。
//
// AppIndicator 只吃路径或主题里的图标名，没有"模板图自动反色"这回事，
// 所以 PNG 是白色的：GNOME / KDE / Ubuntu 的顶栏默认都是深色。浅色顶栏上
// 它会看不清——真要彻底解决得把图标装进 hicolor 主题并按 `-symbolic`
// 命名，那属于打包阶段的事。
gchar* resolve_icon_path() {
  // /proc/self/exe → 可执行文件所在目录 → data/jarvis-tray.png
  // Flutter 的 Linux bundle 布局是 "<bundle>/jarvis_app" + "<bundle>/data/"。
  gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) {
    return nullptr;
  }
  gchar* dir = g_path_get_dirname(exe);
  g_free(exe);
  gchar* path = g_build_filename(dir, "data", "jarvis-tray.png", nullptr);
  g_free(dir);
  if (!g_file_test(path, G_FILE_TEST_EXISTS)) {
    g_free(path);
    return nullptr;
  }
  return path;
}

void on_show_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  TrayIndicator* self = static_cast<TrayIndicator*>(user_data);
  if (self->callbacks.show_window != nullptr) {
    self->callbacks.show_window(self->callbacks.user_data);
  }
}

void on_quit_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  TrayIndicator* self = static_cast<TrayIndicator*>(user_data);
  if (self->callbacks.quit_app != nullptr) {
    self->callbacks.quit_app(self->callbacks.user_data);
  }
}

#ifndef HAVE_AYATANA_APPINDICATOR
// `GtkStatusIcon` 从 GTK 3.14 起整体标了 deprecated，而 runner 带着
// `-Wall -Werror`：不关掉这一段警告，兜底路径根本编译不过。用它是因为
// 目标机可能没装 appindicator 库，没有别的替代。
G_GNUC_BEGIN_IGNORE_DEPRECATIONS

// GtkStatusIcon 才有真正的"左键单击"：直接切换窗口显隐。
//
// AppIndicator 路径没有这个信号——它的主激活被平台定义成"弹菜单"，
// 所以那边只能把「显示主窗口」放在菜单第一项，并用中键做直达。
void on_status_icon_activate(GtkStatusIcon* icon, gpointer user_data) {
  (void)icon;
  TrayIndicator* self = static_cast<TrayIndicator*>(user_data);
  if (self->callbacks.show_window != nullptr) {
    self->callbacks.show_window(self->callbacks.user_data);
  }
}

void on_status_icon_popup_menu(GtkStatusIcon* icon, guint button,
                               guint activate_time, gpointer user_data) {
  (void)icon;
  (void)button;
  (void)activate_time;
  TrayIndicator* self = static_cast<TrayIndicator*>(user_data);
  // 用 3.22 起的 `popup_at_pointer`：老接口 `gtk_menu_popup` 已废弃，
  // 而且它要求传按钮与时间戳，在 Wayland 下还经常弹不出来。
  gtk_menu_popup_at_pointer(GTK_MENU(self->menu), nullptr);
}

G_GNUC_END_IGNORE_DEPRECATIONS
#endif

}  // namespace

TrayIndicator* tray_indicator_new(const TrayIndicatorCallbacks* callbacks) {
  if (callbacks == nullptr || callbacks->show_window == nullptr ||
      callbacks->quit_app == nullptr) {
    return nullptr;
  }

  TrayIndicator* self = g_new0(TrayIndicator, 1);
  self->callbacks = *callbacks;

  self->menu = gtk_menu_new();
  self->show_item = gtk_menu_item_new_with_label("显示主窗口");
  g_signal_connect(self->show_item, "activate", G_CALLBACK(on_show_activate),
                   self);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->menu), self->show_item);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->menu),
                        gtk_separator_menu_item_new());
  GtkWidget* quit_item = gtk_menu_item_new_with_label("退出 Jarvis");
  g_signal_connect(quit_item, "activate", G_CALLBACK(on_quit_activate), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->menu), quit_item);
  gtk_widget_show_all(self->menu);

  gchar* icon_path = resolve_icon_path();

#ifdef HAVE_AYATANA_APPINDICATOR
  // 图标路径缺失时退回主题里的通用图标：能弹出菜单，总比没有入口强。
  self->indicator = app_indicator_new(
      "jarvis", icon_path != nullptr ? icon_path : "application-x-executable",
      APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  if (self->indicator == nullptr) {
    g_free(icon_path);
    gtk_widget_destroy(self->menu);
    g_free(self);
    return nullptr;
  }
  if (icon_path != nullptr) {
    // `app_indicator_new` 的图标参数在部分版本里被当成主题名解析，
    // 再显式设一次完整路径，避免出现"菜单有、图标空白"。
    app_indicator_set_icon_full(self->indicator, icon_path, "Jarvis");
  }
  app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_ACTIVE);
  app_indicator_set_title(self->indicator, "Jarvis");
  app_indicator_set_menu(self->indicator, GTK_MENU(self->menu));
  // 中键直达「显示主窗口」：AppIndicator 的左键被平台占成"弹菜单"了，
  // 这是它能给出的最接近"单击唤回"的动作。
  app_indicator_set_secondary_activate_target(self->indicator,
                                              self->show_item);
#else
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  if (icon_path != nullptr) {
    self->icon = gtk_status_icon_new_from_file(icon_path);
  } else {
    self->icon = gtk_status_icon_new_from_icon_name("application-x-executable");
  }
  if (self->icon == nullptr) {
    g_free(icon_path);
    gtk_widget_destroy(self->menu);
    g_free(self);
    return nullptr;
  }
  gtk_status_icon_set_title(self->icon, "Jarvis");
  gtk_status_icon_set_tooltip_text(self->icon, "Jarvis");
  gtk_status_icon_set_visible(self->icon, TRUE);
  g_signal_connect(self->icon, "activate", G_CALLBACK(on_status_icon_activate),
                   self);
  g_signal_connect(self->icon, "popup-menu",
                   G_CALLBACK(on_status_icon_popup_menu), self);
  G_GNUC_END_IGNORE_DEPRECATIONS
#endif

  g_free(icon_path);
  return self;
}

void tray_indicator_free(TrayIndicator* self) {
  if (self == nullptr) {
    return;
  }
#ifdef HAVE_AYATANA_APPINDICATOR
  if (self->indicator != nullptr) {
    // 先把状态置成 PASSIVE 再解引用：直接释放会让图标在面板上留一小会儿
    // 才消失（进程退出时才被清理）。
    app_indicator_set_status(self->indicator, APP_INDICATOR_STATUS_PASSIVE);
    g_object_unref(self->indicator);
  }
#else
  if (self->icon != nullptr) {
    g_object_unref(self->icon);
  }
#endif
  if (self->menu != nullptr) {
    gtk_widget_destroy(self->menu);
  }
  g_free(self);
}
