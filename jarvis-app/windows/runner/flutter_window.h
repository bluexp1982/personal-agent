#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 把窗口收进通知区域 / 从通知区域唤回。
  //
  // 隐藏用 `ShowWindow(SW_HIDE)` 而不是销毁窗口：窗口一销毁，宿主引擎跟着
  // 没了，常驻就断在这里。
  void HideToTray();
  void ShowFromTray();
  void ToggleFromTray();

  // 真正退出：先摘掉托盘图标，再销毁窗口（`WM_DESTROY` 里 `PostQuitMessage`）。
  void Quit();

  // Enters or leaves the borderless full-screen mode.
  void SetFullScreen(bool full_screen);

  // Tells the shell whether this window should be treated as full screen,
  // so the taskbar steps aside instead of covering the bottom edge.
  void MarkFullScreenInShell(bool full_screen);

  // Pushes the current full-screen state to Flutter. `personal_agent/window`
  // is the same channel macOS uses, so the Dart side stays platform agnostic.
  void NotifyFullScreenChanged();

  // 把一次缩放命令交给 Flutter（`in` / `out` / `reset`）。
  //
  // 与全屏、窗口拖动共用 `personal_agent/window`：Dart 侧只认方法名，
  // 平台差异全部留在原生。
  void NotifyBrowserZoom(const std::string& action);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Window channel shared with the Dart side (`window_chrome.dart`).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // 右栏是否停在可缩放的浏览器页上（由 Dart 经同一通道推送）。
  //
  // 只在为真时把缩放加速键转成事件：没有浏览器页时这几颗键不能被无声吞掉。
  bool browser_zoom_context_active_ = false;

  // 通知区域图标。窗口隐藏后，它是唯一的入口。
  std::unique_ptr<TrayIcon> tray_icon_;

  // Win32 has no full-screen concept, so we emulate it as a borderless window
  // covering the whole monitor. These keep what is needed to put the window
  // back exactly as it was.
  bool is_full_screen_ = false;
  WINDOWPLACEMENT saved_placement_{};
  LONG_PTR saved_style_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
