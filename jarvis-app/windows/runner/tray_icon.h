#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>
// shellapi.h 依赖 windows.h 里的基础类型，顺序不能反。
#include <shellapi.h>

// 通知区域（托盘）图标。
//
// 只做一件事：把 `Shell_NotifyIcon` 的三段生命周期（加、改、删）和那几处
// 老坑收在一处。窗口的显隐、退出语义留在 `FlutterWindow`，这里不认识窗口。
class TrayIcon {
 public:
  TrayIcon() = default;
  ~TrayIcon();

  // 持有的是系统侧的一份注册项，复制出来会变成两个图标，且析构时各删一次。
  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // 添加图标。托盘鼠标事件会以 |callback_message| 投递给 |window|。
  //
  // 返回 false 表示系统侧没加上（explorer 还没起、被组策略禁用等）。
  // 调用方必须据此退回"关窗即退出"，否则会出现"窗口藏了、托盘没有"的死状态。
  bool Add(HWND window, UINT callback_message);

  // 移除图标。重复调用安全。
  void Remove();

  // 图标是否还在系统托盘里。
  bool is_added() const { return added_; }

  // 按当前任务栏明暗重新选图标并刷新。
  //
  // 两个时机必须调：用户在设置里切换了浅色/深色主题（WM_SETTINGCHANGE），
  // 以及 explorer.exe 重启之后（图标需要重新 Add，见 TaskbarCreatedMessage）。
  void RefreshAppearance();

  // 在鼠标位置弹出菜单。菜单命令以 WM_COMMAND 投递给 |window|。
  void ShowMenu(HWND window);

  // 托盘回调消息里判断是哪种点击（lParam 是原始鼠标消息）。
  static bool IsLeftClick(LPARAM lparam);
  static bool IsRightClick(LPARAM lparam);

  // explorer.exe 重启时向所有顶层窗口广播的注册消息。
  //
  // 不处理它，托盘图标会在资源管理器崩溃一次之后永久消失——重启应用才好。
  static UINT TaskbarCreatedMessage();

 private:
  // 静态图标 ID：一个进程只有一个托盘图标，不需要动态分配。
  static constexpr UINT kIconId = 1;

  void LoadIconForSystemTheme();

  HWND window_ = nullptr;
  UINT callback_message_ = 0;
  HICON icon_ = nullptr;
  bool added_ = false;
};

#endif  // RUNNER_TRAY_ICON_H_
