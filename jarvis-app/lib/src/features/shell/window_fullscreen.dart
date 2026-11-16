import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/window_chrome.dart';

/// 原生窗口当前是否处于系统全屏（只读）。
///
/// 与 `immersiveFullscreenProvider` 不是一回事：那边是"界面请求窗口进全屏"，
/// 这里是"窗口现在是不是全屏"——用户直接点绿灯、按 Ctrl+Cmd+F、
/// 或在 Linux 的窗口管理器里全屏，同样算数。
///
/// 目前的消费者是栏头与两处红绿灯留白：macOS 系统全屏会把三颗按钮整组收走，
/// 给它们预留的 78dp 就得让出来，开合按钮顺势回到左端（见 `_RailHeader`）。
/// 状态**不进磁盘**：它由窗口本身决定，重启后重新问一次就好。
final NotifierProvider<WindowFullScreenController, bool>
windowFullScreenProvider = NotifierProvider<WindowFullScreenController, bool>(
  WindowFullScreenController.new,
);

class WindowFullScreenController extends Notifier<bool> {
  bool _disposed = false;

  @override
  bool build() {
    // 原生 → Dart：用户从系统侧进出全屏（绿灯 / Ctrl+Cmd+F / 窗口管理器）。
    listenNativeFullScreenChanges((bool fullScreen) {
      if (_disposed || state == fullScreen) {
        return;
      }
      state = fullScreen;
    });

    // 启动时补问一次：可能就是在全屏里启动的，等不到那条 change 通知。
    unawaited(_syncFromWindow());

    ref.onDispose(() {
      _disposed = true;
    });
    return false;
  }

  Future<void> _syncFromWindow() async {
    final bool? native = await isNativeFullScreen();
    // `null` = 问不到（非桌面平台 / 宿主没注册通道），保持"不是全屏"。
    if (_disposed || native == null || state == native) {
      return;
    }
    state = native;
  }
}
