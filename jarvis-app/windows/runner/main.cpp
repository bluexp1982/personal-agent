#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_shell.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 单实例：窗口收进通知区域后没有任务栏按钮，"再点一次应用图标"是最自然
  // 的动作，每次都会起一个新进程。这里在窗口与引擎创建之前拦掉，并请已经
  // 跑着的那个实例把窗口显示出来。
  //
  // `Local\` 前缀表示只在当前登录会话内唯一——同一台机器上的另一个用户
  // 应当能有自己的一个客户端。
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"Local\\JarvisAppSingleInstance");
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND existing = ::FindWindowW(kWindowClassName, nullptr)) {
      ::PostMessageW(existing, JarvisWakeUpMessage(), 0, 0);
    }
    ::CloseHandle(single_instance);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Jarvis", origin, size)) {
    return EXIT_FAILURE;
  }
  // 这里的"关窗"指窗口被真正销毁。红叉 / Alt+F4 已经在 `WM_CLOSE` 里被
  // 改成"收进托盘"，只有托盘菜单的「退出 Jarvis」会走到销毁，所以这个标志
  // 保持 true 才能让那条退出路径结束消息循环。
  window.SetQuitOnClose(true);

  // 浏览器页面缩放的加速键：Ctrl + `=` / `+`、Ctrl + `-`、Ctrl + `0`。
  //
  // 为什么不用窗口过程里的 WM_KEYDOWN：WebView2 是独立的子 HWND，焦点在
  // 页面里时按键直接进它自己的消息队列，主窗口收不到。加速键在消息循环这
  // 一层先匹配，页面内容获得焦点时也照样生效——与 Chrome 的手感一致。
  //
  // 真正要不要发事件由 `FlutterWindow` 里的上下文标志决定，这里只负责识别。
  ACCEL browser_zoom_keys[] = {
      {FVIRTKEY | FCONTROL, VK_OEM_PLUS, kBrowserZoomInCommand},
      {FVIRTKEY | FCONTROL, VK_ADD, kBrowserZoomInCommand},
      {FVIRTKEY | FCONTROL, VK_OEM_MINUS, kBrowserZoomOutCommand},
      {FVIRTKEY | FCONTROL, VK_SUBTRACT, kBrowserZoomOutCommand},
      {FVIRTKEY | FCONTROL, '0', kBrowserZoomResetCommand},
  };
  HACCEL browser_zoom_accelerators =
      ::CreateAcceleratorTableW(browser_zoom_keys, ARRAYSIZE(browser_zoom_keys));

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    // 命中就已被转成 WM_COMMAND，不再往下派发。
    if (browser_zoom_accelerators != nullptr &&
        ::TranslateAcceleratorW(window.GetHandle(), browser_zoom_accelerators,
                                &msg)) {
      continue;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (browser_zoom_accelerators != nullptr) {
    ::DestroyAcceleratorTable(browser_zoom_accelerators);
  }

  if (single_instance != nullptr) {
    ::CloseHandle(single_instance);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
