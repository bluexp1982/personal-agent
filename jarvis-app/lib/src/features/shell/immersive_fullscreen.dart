import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/window_chrome.dart';

/// 沉浸式全屏当前被谁占着。`null` = 没进沉浸。
///
/// 为什么会是两个宿主：沉浸模式同一时刻只能有一个界面独占窗口，
/// 而"谁按的"决定了布局往哪边让——右栏标签（终端 / 图片、PDF 预览）是
/// 面板吃掉中栏，中栏画布则是中栏吃掉右栏。只存一个 bool 的话，右栏停在
/// 终端标签、中栏又正好是画布时，两边都会认为自己该独占，布局必然选错。
enum ImmersiveSurface {
  /// 右栏当前标签（终端 / 图片、PDF 预览）独占整窗。
  panel,

  /// 中栏当前页（无限画布）独占整窗。
  canvas,
}

/// 沉浸式全屏：让**当前面板标签或中栏页**独占整个窗口。
///
/// 终端、图片 / PDF 预览与无限画布共用这一套，不各做一份：
/// - 进入时请窗口进入原生全屏（桌面端），并藏掉左栏、分隔线、对侧那一栏；
/// - Esc 退出，系统侧退出全屏（macOS 绿灯）也跟着退出；
/// - 与 [panelFullscreenProvider]（`panel_fullscreen.dart`）是两件事：
///   那边是"面板吃掉中栏"，左栏与标签栏都还在；这边是"整台机器只剩这块内容"。
///
/// 哪些内容允许进入由 `HomeShell` 判断（终端、预览、画布），这里只表达
/// "哪个宿主按了按钮"。
///
/// 不进磁盘：全屏是当前窗口的临时视图状态，重启后回到常规布局更符合直觉，
/// 也避免"上次退出时停在满屏终端，下次启动看到一个没有别的界面的窗口"。
final NotifierProvider<ImmersiveFullscreenController, ImmersiveSurface?>
immersiveFullscreenProvider =
    NotifierProvider<ImmersiveFullscreenController, ImmersiveSurface?>(
      ImmersiveFullscreenController.new,
    );

class ImmersiveFullscreenController extends Notifier<ImmersiveSurface?> {
  /// 丢弃过期的异步结果：进入后立刻按 Esc 时，`enter()` 里那次
  /// "查询窗口是否已经全屏"的 await 会在退出之后才回来。
  int _token = 0;

  bool _disposed = false;

  /// 进入前窗口是否已经是原生全屏。`null` = 查询还没回来或问不到。
  bool? _nativeBefore;

  /// 查询是否已经返回过（区分"还在飞"和"问不到"）。
  bool _nativeKnown = false;

  @override
  ImmersiveSurface? build() {
    // 用户从系统侧退出全屏（macOS 绿灯 / Ctrl+Cmd+F、Linux 窗口管理器）：
    // 只把界面复位，绝不再回头调一次原生——窗口已经是用户要的样子了。
    listenNativeFullScreenChanges((bool fullScreen) {
      if (_disposed || fullScreen || state == null) {
        return;
      }
      _forgetNative();
      state = null;
    });

    ref.onDispose(() {
      _disposed = true;
    });
    return null;
  }

  /// 进入沉浸模式：界面立刻切过去，原生窗口随后跟上。
  ///
  /// 界面先切换是刻意的：原生全屏在 macOS 上有一段系统动画（约 0.3s），
  /// 等它结束再改布局，用户会先看到"窗口变大了、但左栏还在"的中间态。
  Future<void> enter(ImmersiveSurface surface) async {
    if (state == surface) {
      return;
    }

    // 已经在沉浸里只换宿主：窗口此刻已经是（或正在变成）全屏，
    // 再走一遍原生流程会把 token 推进一格，让还在飞的那次申请作废。
    if (state != null) {
      state = surface;
      return;
    }

    final int token = ++_token;
    _nativeBefore = null;
    _nativeKnown = false;
    state = surface;
    await _applyNative(token);
  }

  /// 退出沉浸模式：先把界面还原，再按需还原窗口。
  ///
  /// 幂等：Esc、兜底 Focus、面板收起、切标签等多条路径都会调用它。
  void exit() {
    if (state == null) {
      return;
    }
    state = null;
    _token++;

    final bool? before = _nativeBefore;
    final bool known = _nativeKnown;
    _forgetNative();

    // 进入前本来就是全屏 → 保持全屏（"恢复进入前的状态"）。
    // 查询还没回来 → 交给 [_applyNative] 的过期分支去还原。
    if (known && before == false) {
      unawaited(setNativeFullScreen(false));
    }
  }

  Future<void> _applyNative(int token) async {
    final bool? native = await isNativeFullScreen();
    if (_disposed) {
      return;
    }
    _nativeKnown = true;
    _nativeBefore = native;

    if (token != _token) {
      // 查询期间状态已经变过（用户退出、或退出后又进来了一次）。
      // 只有"当前确实是退出状态"才补一次还原：否则会把后一次进入又推回去。
      if (state == null && native == false) {
        await setNativeFullScreen(false);
      }
      return;
    }

    if (native == false) {
      await setNativeFullScreen(true);
    }
  }

  void _forgetNative() {
    _nativeBefore = null;
    _nativeKnown = false;
  }
}
