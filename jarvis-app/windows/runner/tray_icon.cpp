#include "tray_icon.h"

#include <cwchar>

#include "app_shell.h"
#include "resource.h"

namespace {

// 任务栏是不是浅色。
//
// 注意读的是 `SystemUsesLightTheme`（系统 / 任务栏）而不是
// `AppsUseLightTheme`（应用窗口）：这两个在 Windows 里可以分开设，托盘
// 图标贴在任务栏上，只能跟任务栏走。
bool SystemUsesLightTaskbar() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  const LSTATUS status = ::RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
  return status == ERROR_SUCCESS && value != 0;
}

}  // namespace

TrayIcon::~TrayIcon() { Remove(); }

bool TrayIcon::Add(HWND window, UINT callback_message) {
  if (added_) {
    return true;
  }
  window_ = window;
  callback_message_ = callback_message;
  LoadIconForSystemTheme();

  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = callback_message_;
  data.hIcon = icon_;
  // 悬停提示：没有 Dock 图标之后，这是唯一能说明"这个图标是什么"的地方。
  ::lstrcpynW(data.szTip, L"Jarvis", ARRAYSIZE(data.szTip));

  added_ = ::Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  if (!added_) {
    ::OutputDebugStringW(L"[jarvis] 托盘图标添加失败\n");
  }
  return added_;
}

void TrayIcon::Remove() {
  if (!added_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  added_ = false;
}

void TrayIcon::RefreshAppearance() {
  LoadIconForSystemTheme();
  if (!added_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_ICON;
  data.hIcon = icon_;
  ::Shell_NotifyIconW(NIM_MODIFY, &data);
}

void TrayIcon::LoadIconForSystemTheme() {
  // 托盘图标不认模板图，也没有自动反色：白图标落在浅色任务栏上等于消失。
  // 所以出白 / 黑两版资源，按任务栏明暗二选一。
  const int resource =
      SystemUsesLightTaskbar() ? IDI_TRAY_ICON_BLACK : IDI_TRAY_ICON_WHITE;
  const int size = ::GetSystemMetrics(SM_CXSMICON);
  // LR_SHARED：图标句柄由系统管理生命周期，这里不 DestroyIcon，否则下一次
  // 用同一个资源会拿到已被释放的句柄。
  icon_ = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(resource), IMAGE_ICON, size,
      size, LR_SHARED));
}

void TrayIcon::ShowMenu(HWND window) {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kTrayCommandShowWindow, L"显示主窗口");
  ::SetMenuDefaultItem(menu, kTrayCommandShowWindow, FALSE);
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayCommandQuit, L"退出 Jarvis");

  POINT cursor{};
  ::GetCursorPos(&cursor);
  // 先抢前台再弹：不抢的话菜单出来后点窗口别处不会消失，会一直"粘"在
  // 屏幕上。这是 TrackPopupMenu 的老坑，不是可选的最佳实践。
  ::SetForegroundWindow(window);
  ::TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, cursor.x, cursor.y,
                   0, window, nullptr);
  // 菜单关掉后补一条空消息：否则紧接着的第一次点击会被"关闭菜单"吃掉。
  ::PostMessageW(window, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
}

bool TrayIcon::IsLeftClick(LPARAM lparam) {
  return LOWORD(lparam) == WM_LBUTTONUP;
}

bool TrayIcon::IsRightClick(LPARAM lparam) {
  return LOWORD(lparam) == WM_RBUTTONUP;
}

UINT TrayIcon::TaskbarCreatedMessage() {
  static const UINT message = ::RegisterWindowMessageW(L"TaskbarCreated");
  return message;
}
