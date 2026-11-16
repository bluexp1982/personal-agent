import 'package:flutter/material.dart';

import '../../core/design/app_flow_border.dart';

/// 面板外圈的霓虹流光层。
///
/// 只画、不占位：`CustomPaint` 的尺寸由 child 决定，画笔描在 child 的边线上，
/// 所以外面量到的矩形与不挂本组件时逐像素一致——`kChatComposerPanelKey`
/// 的量尺寸测试不因此变化。
///
/// 三层职责分开：
/// - [active] 只表达"该不该亮"，不关心业务（是不是在等首个 token 由页面判断）；
/// - 旋转控制器由 painter 的 `repaint` 直接驱动，不经过 `setState`，
///   动画期间 widget 树不重建；
/// - 淡入淡出单独一个控制器，只在这 280ms 内重建 painter。
class ComposerFlowBorder extends StatefulWidget {
  const ComposerFlowBorder({
    super.key,
    required this.active,
    required this.radius,
    required this.child,
  });

  /// 是否显示流光。由调用方决定（发送后等待首个 token 期间为真）。
  final bool active;

  /// 面板圆角，与面板自身的 `BorderRadius` 保持一致才能贴住边。
  final double radius;

  final Widget child;

  @override
  State<ComposerFlowBorder> createState() => _ComposerFlowBorderState();
}

class _ComposerFlowBorderState extends State<ComposerFlowBorder>
    with TickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: AppFlowBorder.period,
  );

  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AppFlowBorder.fadeDuration,
  );

  /// 系统开了「减少动态效果」。
  ///
  /// 此时保留静态彩虹描边（它仍在告诉用户"正在等"），只是不让光带转；
  /// 淡入淡出也直接切，避免"关掉动画却还在渐变"的半吊子降级。
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    // 淡出结束才停旋转：淡到一半停住会像卡在某个相位。
    _fade.addStatusListener(_onFadeStatus);
    if (widget.active) {
      _fade.value = 1;
      _rotation.repeat();
    }
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      _rotation.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 变化（切换系统动效设置）也要重新决定，不能只在 initState 读一次。
    _sync();
  }

  @override
  void didUpdateWidget(covariant ComposerFlowBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _sync();
    }
  }

  /// 按 [active] 与系统的动效开关调整两个控制器。
  void _sync() {
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    if (widget.active) {
      if (_reduceMotion) {
        _fade.stop();
        _fade.value = 1;
        _rotation.stop();
        _rotation.value = 0;
        return;
      }
      if (!_rotation.isAnimating) {
        _rotation.repeat();
      }
      _fade.forward();
      return;
    }

    if (_reduceMotion) {
      _fade.stop();
      _fade.value = 0;
      _rotation.stop();
      return;
    }
    _fade.reverse();
  }

  @override
  void dispose() {
    _fade.removeStatusListener(_onFadeStatus);
    _fade.dispose();
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;

    return AnimatedBuilder(
      animation: _fade,
      // `child` 走缓存：淡入淡出时只有 CustomPaint 这一层重建，面板内容不重建。
      child: widget.child,
      builder: (context, child) {
        final opacity = _fade.value;
        // 完全透明时连 CustomPaint 都不挂：空闲期这张面板与改造前完全相同，
        // 不常驻一层图层、也不会因为 painter 而多一次重绘。
        if (opacity <= 0) {
          return child!;
        }
        return RepaintBoundary(
          child: CustomPaint(
            foregroundPainter: _FlowBorderPainter(
              rotation: _rotation,
              radius: widget.radius,
              opacity: opacity,
              brightness: brightness,
            ),
            child: child,
          ),
        );
      },
    );
  }
}

/// 描两遍同色渐变：先宽而虚的外发光，再贴边的亮线。
///
/// 不沿圆角矩形逐段切片，是因为那要每帧构造几十上百条 `Path`，圆角处还容易
/// 出缝；`SweepGradient` 一次 `createShader` 交给 GPU，成本与面板尺寸无关。
class _FlowBorderPainter extends CustomPainter {
  _FlowBorderPainter({
    required this.rotation,
    required this.radius,
    required this.opacity,
    required this.brightness,
  }) : super(repaint: rotation);

  /// 圈数来源。painter 直接监听它，每帧只重绘不重建 widget。
  final Animation<double> rotation;

  final double radius;
  final double opacity;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) {
      return;
    }

    // 描边中心压在面板边线上：向内各收半个描边宽，右/下边才不会被自身尺寸截掉。
    final inset = AppFlowBorder.strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final turns = rotation.value;

    final glowAlpha =
        (brightness == Brightness.dark
            ? AppFlowBorder.glowAlphaDark
            : AppFlowBorder.glowAlphaLight) *
        opacity;

    // 外发光：宽描边 + 大模糊。画在面板底色之外，靠父级不裁剪才能透出去。
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppFlowBorder.glowWidth
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          AppFlowBorder.glowSigma,
        )
        ..shader = AppFlowBorder.gradient(
          turns: turns,
          opacity: glowAlpha,
        ).createShader(rect),
    );

    // 贴边亮边：窄描边 + 小模糊，把光晕收成一条线。
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppFlowBorder.strokeWidth
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          AppFlowBorder.edgeSigma,
        )
        ..shader = AppFlowBorder.gradient(
          turns: turns,
          opacity: opacity,
        ).createShader(rect),
    );

    // 芯线：不模糊，保证边缘在任何底色上都读得出"有一圈边"。
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppFlowBorder.strokeWidth * 0.7
        ..shader = AppFlowBorder.gradient(
          turns: turns,
          opacity: opacity,
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _FlowBorderPainter oldDelegate) {
    return oldDelegate.opacity != opacity ||
        oldDelegate.radius != radius ||
        oldDelegate.brightness != brightness ||
        !identical(oldDelegate.rotation, rotation);
  }
}
