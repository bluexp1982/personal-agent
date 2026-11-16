import 'package:flutter/material.dart';

/// 右栏空白页（「新标签页」）标签上的图标：一枚指南针。
///
/// 形状照参考图：细圆环 + 一根斜置的针。但参考图里那根针是实心的
/// （Material `explore` 的写法），跟标签栏其它图标（终端、地球、预览）
/// 的线性风格不是一套；这里把针描成空心的细菱形，圆角、线宽、
/// 24 格栅的取法与同目录那批自绘图标（`panel_fullscreen_icon.dart`、
/// `project_icon.dart`）同口径。
class PanelStartIcon extends StatelessWidget {
  const PanelStartIcon({super.key, this.size = 13, this.color});

  /// 默认 13，等于标签里图标那一格（`kPanelTabIconSize`）：图标跟着
  /// 内置的那批 Material 图标走同一个渲染尺寸，换掉谁都不会让文字挪位。
  final double size;

  /// 不传时跟随 `IconTheme`：选中 / 未选中的颜色由标签自己给。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved =
        color ?? IconTheme.of(context).color ?? scheme.onSurfaceVariant;

    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _PanelStartPainter(color: resolved)),
    );
  }
}

/// 在 24×24 的设计栅格里描，再整体缩放到目标尺寸。
///
/// 栅格与线宽刻意选成和 Material 图标集一样（24 格、2 号线）：标签栏里
/// 挨着的终端 / 地球图标就是这个口径，缩放后三者的笔画重量才对得上。
class _PanelStartPainter extends CustomPainter {
  const _PanelStartPainter({required this.color});

  final Color color;

  static const double _grid = 24;
  static const double _strokeWidth = 2.0;

  /// 圆环半径：留出 1.5 个单位的边距，笔画不会顶到图标格边缘。
  static const double _radius = 9.2;

  /// 指针的长轴是一整条 45° 对角线，两端尖落在 (15.6,8.4) / (8.4,15.6)
  /// （离圆心约 0.55r，与参考图量出来的比例一致）；
  /// 两个侧翼沿垂直方向各偏 [_needleHalfWidth]，菱形因此细长。
  static const Offset _tipNE = Offset(15.6, 8.4);
  static const Offset _tipSW = Offset(8.4, 15.6);
  static const double _needleHalfWidth = 1.9;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _grid);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas
      ..drawCircle(const Offset(_grid / 2, _grid / 2), _radius, paint)
      ..drawPath(_needle(), paint);

    canvas.restore();
  }

  /// 指针：中心对称的细菱形。
  ///
  /// 不用 `rotate` 画一个直菱形，是因为长轴要正好压在 45° 对角线上、
  /// 且两端尖得落在整数坐标上；直接把四个点写出来，缩放后不会因为
  /// 旋转矩阵的取整而歪半像素。
  Path _needle() {
    const center = Offset(_grid / 2, _grid / 2);
    // 垂直于对角线的单位向量 (1,1)/√2，乘上半宽得到两个侧翼点。
    const wing = Offset(0.7071, 0.7071);
    final sideA = center + wing * _needleHalfWidth;
    final sideB = center - wing * _needleHalfWidth;

    return Path()
      ..moveTo(_tipNE.dx, _tipNE.dy)
      ..lineTo(sideA.dx, sideA.dy)
      ..lineTo(_tipSW.dx, _tipSW.dy)
      ..lineTo(sideB.dx, sideB.dy)
      ..close();
  }

  @override
  bool shouldRepaint(_PanelStartPainter oldDelegate) =>
      oldDelegate.color != color;
}
