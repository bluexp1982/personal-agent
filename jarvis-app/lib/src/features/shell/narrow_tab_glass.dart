import 'package:flutter/material.dart';

/// 胶囊边缘玻璃层的 Key（测试用来确认"这一层在、且不拦点击"）。
const Key kBottomNavGlassKey = Key('narrow-bottom-glass');

/// 导航胶囊的玻璃质感边缘：色散、镜面高光、以及倒角的明暗两面。
///
/// 只负责画，不碰主题——颜色都由调用方从 `core/design` 派生传入：
/// - [highlight] / [bottomGlow] 取 `AppColors.onAccent` 的不同透明度；
/// - [warmEdge] / [coolEdge] 取 `palette.accent.projectStart` 与 `scheme.primary`，
///   两侧各偏一点色温，模拟玻璃边缘把背景光散开；
/// - [topShade] 取 `scheme.shadow`，压出"顶壁比底壁厚"的错觉。
///
/// 为什么不写成 `BoxDecoration.border`：`Border.all` 只有单色，表达不了
/// 「左上亮、右下透明」；而且胶囊本体刻意不画描边（边界靠阴影与底色表达），
/// 这些层只能单独绘制。
///
/// 这里的明暗是"厚度"的来源：透镜只负责让背景变形，玻璃看起来是不是一块
/// 有体积的东西，靠的是顶壁那圈暗、底壁那圈亮。
class NarrowTabGlassEdge extends CustomPainter {
  const NarrowTabGlassEdge({
    required this.radius,
    required this.highlight,
    required this.warmEdge,
    required this.coolEdge,
    required this.topShade,
    required this.bottomGlow,
  });

  /// 与胶囊同心的圆角半径（胶囊半高，由绘制时 clamp 得到）。
  final double radius;

  /// 镜面高光色：左上亮、右下透明。
  final Color highlight;

  /// 暖侧色散。
  final Color warmEdge;

  /// 冷侧色散。
  final Color coolEdge;

  /// 顶部内壁的暗边：玻璃上沿被压深的阴影。
  final Color topShade;

  /// 底部内壁的反光：玻璃下沿把光弹回来的一层亮。
  final Color bottomGlow;

  /// 倒角暗/亮边覆盖的高度（自对应边缘算起）。
  static const double _bevelHeight = 10;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );

    // ① 色散先画：同一条弧上下各偏 1pt，随后被高光压住一半，
    //    只在弧的外侧露出一丝，斜看时边缘会泛色。
    canvas.drawRRect(
      rrect.shift(const Offset(0, 1)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = warmEdge,
    );
    canvas.drawRRect(
      rrect.shift(const Offset(0, -1)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = coolEdge,
    );

    // ② 镜面高光：往里让半个描边宽，弧线落在边界内侧，不会糊出胶囊外。
    final edge = rrect.deflate(0.5);
    final transparent = highlight.withValues(alpha: 0);
    canvas.drawRRect(
      edge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[highlight, transparent, transparent],
          stops: const <double>[0, 0.3, 1],
        ).createShader(edge.outerRect),
    );

    // ③④ 倒角的两面：必须裁剪在胶囊形状里，否则会在圆角外侧画出方块。
    canvas.save();
    canvas.clipRRect(edge);

    final double bevel = _bevelHeight;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, bevel),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[topShade, topShade.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, bevel)),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - bevel * 0.8, size.width, bevel * 0.8),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            bottomGlow.withValues(alpha: 0),
            bottomGlow,
          ],
        ).createShader(
          Rect.fromLTWH(0, size.height - bevel * 0.8, size.width, bevel * 0.8),
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(NarrowTabGlassEdge old) =>
      old.radius != radius ||
      old.highlight != highlight ||
      old.warmEdge != warmEdge ||
      old.coolEdge != coolEdge ||
      old.topShade != topShade ||
      old.bottomGlow != bottomGlow;
}
