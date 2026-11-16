#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>

#include <cwchar>
#include <optional>

#include "app_shell.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

// `DWMWA_WINDOW_CORNER_PREFERENCE` and its values only exist in the Windows 11
// SDK; redefine them so this still compiles against an older one.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33

enum DWM_WINDOW_CORNER_PREFERENCE {
  DWMWCP_DEFAULT = 0,
  DWMWCP_DONOTROUND = 1,
  DWMWCP_ROUND = 2,
  DWMWCP_ROUNDSMALL = 3,
};
#endif

// The shell's taskbar list. Reused for the whole process: creating it per call
// would leak a COM object on every toggle.
ITaskbarList2* GetTaskbarList() {
  static ITaskbarList2* taskbar = []() -> ITaskbarList2* {
    ITaskbarList2* list = nullptr;
    if (FAILED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list)))) {
      return nullptr;
    }
    if (FAILED(list->HrInit())) {
      list->Release();
      return nullptr;
    }
    return list;
  }();
  return taskbar;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "personal_agent/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "isFullScreen") {
          result->Success(flutter::EncodableValue(is_full_screen_));
          return;
        }
        if (method == "setFullScreen") {
          bool full_screen = false;
          if (const auto* arguments =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto entry = arguments->find(flutter::EncodableValue("fullScreen"));
            if (entry != arguments->end()) {
              if (const bool* value = std::get_if<bool>(&entry->second)) {
                full_screen = *value;
              }
            }
          }
          SetFullScreen(full_screen);
          result->Success();
          return;
        }
        if (method == "setBrowserZoomContext") {
          // Dart 侧声明"现在停在一个可缩放的浏览器页上"；只有为真时下面的
          // 加速键才会转成缩放命令。
          bool active = false;
          if (const auto* arguments =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto entry = arguments->find(flutter::EncodableValue("active"));
            if (entry != arguments->end()) {
              if (const bool* value = std::get_if<bool>(&entry->second)) {
                active = *value;
              }
            }
          }
          browser_zoom_context_active_ = active;
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  // 托盘图标：窗口隐藏后唯一的入口。加不上时不抛错——`WM_CLOSE` 分支会
  // 退回"关窗即退出"的旧行为，不会出现"窗口藏了、图标也没有"的死状态。
  tray_icon_ = std::make_unique<TrayIcon>();
  tray_icon_->Add(GetHandle(), kTrayCallbackMessage);

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 先摘托盘图标：进程退出后图标会残留在通知区域，直到鼠标划过才消失。
  // `TrayIcon` 记着创建时拿到的 HWND 与图标 ID，这里窗口已经销毁也能删掉。
  if (tray_icon_) {
    tray_icon_->Remove();
    tray_icon_.reset();
  }

  // 再拆通道：它的析构会往 messenger 上注销处理器，而 messenger 属于引擎，
  // 顺序反过来就是在已销毁的引擎上调方法。
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 单实例：第二个进程投递的"请把窗口显示出来"。
  if (message == JarvisWakeUpMessage()) {
    ShowFromTray();
    return 0;
  }

  // 资源管理器重启后系统会清空所有托盘图标，自己加回来。
  if (message == TrayIcon::TaskbarCreatedMessage()) {
    if (tray_icon_) {
      // 先 Remove 复位本地状态：`Add` 见到 `added_` 为真会直接返回，
      // 不先复位的话图标在 explorer 重启后永远不会回来。
      // 这一步的 NIM_DELETE 对已被清空的图标是空操作。
      tray_icon_->Remove();
      tray_icon_->Add(hwnd, kTrayCallbackMessage);
    }
    return 0;
  }

  // 托盘图标的鼠标事件（`NOTIFYICONDATAW::uCallbackMessage`）。
  if (message == kTrayCallbackMessage) {
    if (TrayIcon::IsLeftClick(lparam)) {
      ToggleFromTray();
    } else if (TrayIcon::IsRightClick(lparam)) {
      if (tray_icon_) {
        tray_icon_->ShowMenu(hwnd);
      }
    }
    return 0;
  }

  // 红叉 / Alt+F4 / 任务栏右键「关闭窗口」：一律改为收进通知区域。
  //
  // 托盘没加上时什么都不做，落到下面走默认销毁流程——保留旧的"关窗即
  // 退出"，总好过窗口藏起来又没有图标唤回。
  if (message == WM_CLOSE && tray_icon_ && tray_icon_->is_added()) {
    HideToTray();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_COMMAND: {
      const UINT command = LOWORD(wparam);
      // 浏览器缩放加速键（见 `main.cpp` 的加速键表）。Dart 没声明上下文时
      // 只吞掉这次按键、不发事件：别处没有用这几颗键，但也别凭空改状态。
      if (command == kBrowserZoomInCommand ||
          command == kBrowserZoomOutCommand ||
          command == kBrowserZoomResetCommand) {
        if (browser_zoom_context_active_) {
          NotifyBrowserZoom(command == kBrowserZoomInCommand
                                ? "in"
                                : (command == kBrowserZoomOutCommand ? "out"
                                                                     : "reset"));
        }
        return 0;
      }
      // 托盘菜单投递回来的命令。
      if (command == kTrayCommandShowWindow) {
        ShowFromTray();
        return 0;
      }
      if (command == kTrayCommandQuit) {
        Quit();
        return 0;
      }
      break;
    }
    case WM_SETTINGCHANGE:
      // 系统主题切换：任务栏明暗变了，托盘图标要跟着换配色，否则会在
      // 同色背景上"消失"。
      if (lparam != 0 &&
          std::wcscmp(reinterpret_cast<const wchar_t*>(lparam),
                      L"ImmersiveColorSet") == 0 &&
          tray_icon_) {
        tray_icon_->RefreshAppearance();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::SetFullScreen(bool full_screen) {
  HWND hwnd = GetHandle();
  if (!hwnd || full_screen == is_full_screen_) {
    return;
  }

  if (full_screen) {
    // Remember everything needed to put the window back: the frame style and
    // the placement (which also covers "was it maximized before?").
    saved_placement_.length = sizeof(saved_placement_);
    ::GetWindowPlacement(hwnd, &saved_placement_);
    saved_style_ = ::GetWindowLongPtr(hwnd, GWL_STYLE);

    HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (!::GetMonitorInfo(monitor, &info)) {
      return;
    }
    // `rcMonitor` rather than `rcWork`: a full-screen window must also cover
    // the strip the taskbar normally occupies.
    const RECT& bounds = info.rcMonitor;

    ::SetWindowLongPtr(hwnd, GWL_STYLE,
                       WS_POPUP | WS_VISIBLE | WS_CLIPCHILDREN |
                           WS_CLIPSIBLINGS);
    // Tell the shell first, otherwise the taskbar keeps its topmost slot for
    // a moment and clips the bottom of the window.
    MarkFullScreenInShell(true);
    ::SetWindowPos(hwnd, HWND_TOP, bounds.left, bounds.top,
                   bounds.right - bounds.left, bounds.bottom - bounds.top,
                   SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);

    // Windows 11 rounds every window corner by default; in full screen that
    // leaves four slivers of desktop visible.
    const DWORD corner = DWMWCP_DONOTROUND;
    ::DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner,
                            sizeof(corner));
  } else {
    MarkFullScreenInShell(false);
    ::SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
    if (saved_placement_.length != 0) {
      ::SetWindowPlacement(hwnd, &saved_placement_);
    }
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                       SWP_NOZORDER | SWP_NOOWNERZORDER);

    const DWORD corner = DWMWCP_DEFAULT;
    ::DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner,
                            sizeof(corner));
  }

  is_full_screen_ = full_screen;
  NotifyFullScreenChanged();
}

void FlutterWindow::MarkFullScreenInShell(bool full_screen) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  if (ITaskbarList2* taskbar = GetTaskbarList()) {
    taskbar->MarkFullscreenWindow(hwnd, full_screen ? TRUE : FALSE);
  }
}

void FlutterWindow::NotifyFullScreenChanged() {
  if (!window_channel_) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("fullScreen")] =
      flutter::EncodableValue(is_full_screen_);
  window_channel_->InvokeMethod(
      "fullScreenChanged",
      std::make_unique<flutter::EncodableValue>(arguments));
}

void FlutterWindow::NotifyBrowserZoom(const std::string& action) {
  if (!window_channel_) {
    return;
  }
  flutter::EncodableMap arguments;
  arguments[flutter::EncodableValue("action")] =
      flutter::EncodableValue(action);
  window_channel_->InvokeMethod(
      "browserZoom", std::make_unique<flutter::EncodableValue>(arguments));
}

void FlutterWindow::HideToTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  if (is_full_screen_) {
    // 无边框全屏是这个类自己模拟的：不先还原样式就隐藏，下次唤回会是一扇
    // 铺满监视器、没有标题栏、也切不回来的窗口。这一步同时会通过
    // `fullScreenChanged` 让界面退出沉浸态。
    SetFullScreen(false);
  }
  ::ShowWindow(hwnd, SW_HIDE);
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
  // 焦点要显式交回 Flutter 视图：只 `SetForegroundWindow` 的话，画面上是
  // 窗口，但输入法与光标要等用户再点一下才进来。
  if (flutter_controller_ && flutter_controller_->view()) {
    ::SetFocus(flutter_controller_->view()->GetNativeWindow());
  }
}

void FlutterWindow::ToggleFromTray() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  // 只有"已经是前台窗口"才算用户想藏：被别的窗口盖住时，点图标的意思是把
  // 窗口拿到前面，不是再藏一次。
  const bool is_front =
      ::IsWindowVisible(hwnd) != FALSE && ::GetForegroundWindow() == hwnd;
  if (is_front) {
    HideToTray();
  } else {
    ShowFromTray();
  }
}

void FlutterWindow::Quit() {
  if (tray_icon_) {
    tray_icon_->Remove();
  }
  HWND hwnd = GetHandle();
  if (hwnd) {
    // 销毁窗口会走到 `WM_DESTROY`，那里按 `quit_on_close_` 发
    // `PostQuitMessage`，消息循环随之结束。
    ::DestroyWindow(hwnd);
  }
}
