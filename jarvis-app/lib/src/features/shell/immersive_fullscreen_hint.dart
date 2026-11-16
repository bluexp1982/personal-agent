import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design/app_tokens.dart';

/// 提示文案。测试按它定位，改文案时只改这一处。
const String kImmersiveFullscreenHintText = '全屏 · 按 Esc 退出';

/// 进入沉浸式全屏时的一次性提示。
///
/// 状态栏、标签栏、左栏全都被藏起来了，用户需要一句话告诉他"这是全屏，
/// 按 Esc 就回去"——否则满屏内容很容易被当成界面坏了。
///
/// 终端、图片 / PDF 预览与无限画布共用：提示语不点名具体内容。
///
/// 约束：
/// - 不拦截鼠标（`IgnorePointer`）：贴在顶部的药丸不能挡住内容；
/// - 只在**进入**时弹一次，[visible] 变回 false 时立刻收掉（退出全屏不需要再提示）；
/// - 定时器必须在 `dispose` 里取消，否则 widget 测试会报 pending timer。
class ImmersiveFullscreenHint extends StatefulWidget {
  const ImmersiveFullscreenHint({super.key, required this.visible});

  /// 是否处于沉浸式全屏。由 false → true 时弹一次，随后自动淡出。
  final bool visible;

  @override
  State<ImmersiveFullscreenHint> createState() =>
      _ImmersiveFullscreenHintState();
}

class _ImmersiveFullscreenHintState extends State<ImmersiveFullscreenHint> {
  /// 停留时长：够看清一行字，又不至于一直压在内容顶部。
  static const Duration _hold = Duration(milliseconds: 2400);
  static const Duration _fade = Duration(milliseconds: 220);

  Timer? _timer;
  bool _opaque = false;

  @override
  void initState() {
    super.initState();
    if (widget.visible) {
      _show();
    }
  }

  @override
  void didUpdateWidget(covariant ImmersiveFullscreenHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.visible && widget.visible) {
      _show();
    } else if (oldWidget.visible && !widget.visible) {
      _hide();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _show() {
    _timer?.cancel();
    _opaque = true;
    _timer = Timer(_hold, () {
      if (!mounted) {
        return;
      }
      setState(() => _opaque = false);
    });
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    if (_opaque) {
      setState(() => _opaque = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _opaque ? 1 : 0,
        duration: _fade,
        curve: Curves.easeOut,
        // 淡出之后仍然是一层零尺寸的浮层：`IgnorePointer` 保证它此刻也不吃事件。
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.inverseSurface.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.fullscreen_rounded,
                size: 14,
                color: scheme.onInverseSurface,
              ),
              const SizedBox(width: 6),
              Text(
                kImmersiveFullscreenHintText,
                style: TextStyle(
                  color: scheme.onInverseSurface,
                  fontSize: AppFontSize.sm,
                  fontWeight: AppWeight.semiBold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
