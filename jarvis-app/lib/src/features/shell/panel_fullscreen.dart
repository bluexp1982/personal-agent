import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 右侧面板全屏开关：让面板吃掉「中栏 + 右栏」整块区域。
///
/// 左侧栏刻意保留：全屏是"把面板放大"，不是"换一个只剩终端的界面"。
/// 左栏还在，用户全屏看终端/文件时仍能切项目、切会话，也随时拖得回去。
///
/// 与 `immersive_fullscreen.dart` 的「沉浸式全屏」是两套并列的模式，不要合并：
/// 那边连左栏、中栏、标签栏都藏掉，并且会请窗口进入原生全屏（终端、图片 /
/// PDF 预览与中栏画布共用）；这边是面板自己的视图状态，任何标签（文件、预览、浏览器）都适用。
/// 终端状态栏、预览文件头与画布栏头上那颗「全屏」按钮进的是沉浸式全屏，不是这个。
///
/// 这是**当前窗口的临时视图状态**，所以故意不落盘：重启后回到常规布局更符合直觉，
/// 也避免与 `ui_project_mode` 那类"上次看到哪儿"的偏好混在一起——
/// 万一上次退出时停在满屏面板，下次启动就会看到一个没有中间区的界面。
///
/// 是否真的按全屏渲染还要与「面板可见」一起判断（见 `HomeShell`）：
/// 这里只表达用户按下了全屏按钮。
final NotifierProvider<PanelFullscreenController, bool>
panelFullscreenProvider = NotifierProvider<PanelFullscreenController, bool>(
  PanelFullscreenController.new,
);

class PanelFullscreenController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  /// 幂等：隐藏面板、关闭终端标签、断开连接等多条路径都会调用它。
  void exit() {
    if (state) {
      state = false;
    }
  }
}
