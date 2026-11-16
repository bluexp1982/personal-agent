import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/browser/browser_controller.dart';
import '../../core/browser/browser_zoom.dart';
import '../../core/window_chrome.dart';
import '../shell/file_pane_state.dart';

/// 右栏此刻是否停在"可缩放的浏览器页"上。
///
/// 两个条件同时成立才算：右栏可见（收起时页面不在屏幕上，快捷键不该生效）
/// 且当前标签是浏览器（文件 / 终端 / 预览标签下不该抢缩放键）。
final browserZoomShortcutActiveProvider = Provider<bool>((ref) {
  if (!ref.watch(filePaneVisibleProvider)) {
    return false;
  }
  final id = ref.watch(
    filePaneTabProvider.select((state) => state.activeBrowserId),
  );
  if (id == null) {
    return false;
  }
  // 还没打开页面的浏览器标签不算：那时没有内容可缩放，抢走 Cmd+0 只会让人
  // 以为快捷键坏了。`hasPage` 在页面打开/关闭时会变，原生那边跟着切。
  return ref.watch(browserSessionProvider(id).select((state) => state.hasPage));
});

/// 把浏览器缩放的原生快捷键接到当前活动标签上。
///
/// 桌面端（macOS / Windows）由原生在页面内容拿到键盘焦点时识别组合键，
/// 再经 `personal_agent/window` 发回来；没有这层，WKWebView / WebView2
/// 会把按键全吃掉，Flutter 侧的 `Shortcuts` 根本收不到。
///
/// 移动端没有可接的原生键盘通道，这里用 [CallbackShortcuts] 兜底：
/// 仅当地址栏等 Flutter 控件聚焦时生效，页面内容聚焦时不生效——这是显式的
/// 平台边界，不做"看起来能用、实际时灵时不灵"的假承诺。
class BrowserZoomShortcutHost extends ConsumerStatefulWidget {
  const BrowserZoomShortcutHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<BrowserZoomShortcutHost> createState() =>
      _BrowserZoomShortcutHostState();
}

class _BrowserZoomShortcutHostState
    extends ConsumerState<BrowserZoomShortcutHost> {
  VoidCallback? _unsubscribe;

  @override
  void initState() {
    super.initState();
    _unsubscribe = listenBrowserZoomShortcuts(_handleCommand);
    // 首帧补一次首值：`ref.listen` 默认只在变化时回调，而挂载这天原生
    // 那边可能还停在上一张标签留下的 `false`。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        setBrowserZoomShortcutActive(
          ref.read(browserZoomShortcutActiveProvider),
        ),
      );
    });
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    // 宿主拆掉（切走标签、收起右栏）后原生必须恢复"别吞我的键"。
    unawaited(setBrowserZoomShortcutActive(false));
    super.dispose();
  }

  /// 把一次缩放动作落到"此刻真正在看的那一页"。
  ///
  /// 收到命令时再读一次 provider，而不是在订阅时记住 tabId：原生命令是全局的，
  /// 期间用户可能已经切了标签。
  void _handleCommand(BrowserZoomCommand command) {
    if (!mounted) {
      return;
    }
    if (!ref.read(filePaneVisibleProvider)) {
      return;
    }
    final id = ref.read(filePaneTabProvider).activeBrowserId;
    if (id == null) {
      return;
    }
    final controller = ref.read(browserSessionProvider(id).notifier);
    switch (command) {
      case BrowserZoomCommand.zoomIn:
        controller.zoomIn();
      case BrowserZoomCommand.zoomOut:
        controller.zoomOut();
      case BrowserZoomCommand.reset:
        controller.resetZoom();
    }
  }

  /// 移动端兜底：Ctrl 或 Cmd + `=` / `-` / `0`。
  ///
  /// 物理键盘上放大通常按的是 `+`，那是 `Shift + =`，所以带 Shift 的一档
  /// 也要绑；小键盘的加减号同理。
  Map<ShortcutActivator, VoidCallback> _fallbackShortcuts() {
    final bindings = <ShortcutActivator, VoidCallback>{};

    void bind({required bool control, required bool meta}) {
      void on(LogicalKeyboardKey key, VoidCallback action, {bool shift = false}) {
        bindings[SingleActivator(
          key,
          control: control,
          meta: meta,
          shift: shift,
        )] = action;
      }

      on(
        LogicalKeyboardKey.equal,
        () => _handleCommand(BrowserZoomCommand.zoomIn),
      );
      on(
        LogicalKeyboardKey.equal,
        () => _handleCommand(BrowserZoomCommand.zoomIn),
        shift: true,
      );
      on(
        LogicalKeyboardKey.numpadAdd,
        () => _handleCommand(BrowserZoomCommand.zoomIn),
      );
      on(
        LogicalKeyboardKey.minus,
        () => _handleCommand(BrowserZoomCommand.zoomOut),
      );
      on(
        LogicalKeyboardKey.numpadSubtract,
        () => _handleCommand(BrowserZoomCommand.zoomOut),
      );
      on(
        LogicalKeyboardKey.digit0,
        () => _handleCommand(BrowserZoomCommand.reset),
      );
    }

    bind(control: true, meta: false);
    bind(control: false, meta: true);
    return bindings;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(browserZoomShortcutActiveProvider, (_, next) {
      unawaited(setBrowserZoomShortcutActive(next));
    });

    return CallbackShortcuts(
      bindings: _fallbackShortcuts(),
      child: widget.child,
    );
  }
}
