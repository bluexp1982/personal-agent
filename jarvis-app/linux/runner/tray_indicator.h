#ifndef RUNNER_TRAY_INDICATOR_H_
#define RUNNER_TRAY_INDICATOR_H_

#include <gtk/gtk.h>

// 状态栏（托盘）指示器。
//
// 两条实现，编译期二选一：
//   - libayatana-appindicator：GNOME / KDE / Ubuntu 的现代路径。注意 AppIndicator
//     的平台语义就是"主激活 = 弹菜单"，没有"左键直达某个动作"这回事；
//   - GtkStatusIcon：库缺失时的兜底，X11 下可用，Wayland 下多数合成器不显示。
//     这一条路径才有真正的"左键单击"信号。
//
// 谁拥有窗口不归这里管：这里只把"用户点了什么"回调出去，避免和
// `my_application.cc` 里的窗口生命周期缠绕在一起。
typedef struct _TrayIndicator TrayIndicator;

typedef struct {
  // 用户选择「显示主窗口」。
  void (*show_window)(gpointer user_data);
  // 用户选择「退出 Jarvis」。
  void (*quit_app)(gpointer user_data);
  gpointer user_data;
} TrayIndicatorCallbacks;

// 创建指示器。返回 nullptr 表示两条路径都没建起来（例如缺图标且缺库），
// 调用方必须让"关窗即退出"的旧行为继续生效。
TrayIndicator* tray_indicator_new(const TrayIndicatorCallbacks* callbacks);

void tray_indicator_free(TrayIndicator* self);

#endif  // RUNNER_TRAY_INDICATOR_H_
