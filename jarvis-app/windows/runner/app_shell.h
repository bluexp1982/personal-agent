#ifndef RUNNER_APP_SHELL_H_
#define RUNNER_APP_SHELL_H_

#include <windows.h>

// 主窗口类名。
//
// 从 `win32_window.cpp` 提到头文件：单实例检查（`main.cpp`）要按类名找到
// 已经跑着的那个窗口，两边各写一份字面量迟早会改漏一处，那时表现是
// "第二个实例找不到窗口，于是又开了一个"。
constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// 托盘图标把鼠标事件投递回主窗口时用的消息号。WM_APP 段留给应用自己，
// 不会与系统消息冲突。
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// 托盘菜单命令 ID。40001 起是标准的应用自定义段（`resource.h` 里的
// `_APS_NEXT_COMMAND_VALUE` 也是这个起点）。
constexpr UINT kTrayCommandShowWindow = 40001;
constexpr UINT kTrayCommandQuit = 40002;

// 浏览器页面缩放的加速键命令 ID。
//
// 与托盘命令同一段编号，但来源不同：这些由 `main.cpp` 的加速键表发出，
// 经 `WM_COMMAND` 回到 `FlutterWindow`，再由窗口通道转发给 Dart。
constexpr UINT kBrowserZoomInCommand = 40011;
constexpr UINT kBrowserZoomOutCommand = 40012;
constexpr UINT kBrowserZoomResetCommand = 40013;

// "请把窗口显示出来"的注册消息。
//
// 必须用 `RegisterWindowMessage` 取系统范围内唯一的 ID：第二个实例要用
// `PostMessage` 跨进程投递，两边各自写死一个 WM_APP+n 会撞上别的应用。
inline UINT JarvisWakeUpMessage() {
  static const UINT message =
      ::RegisterWindowMessageW(L"JarvisAppShowWindow");
  return message;
}

#endif  // RUNNER_APP_SHELL_H_
