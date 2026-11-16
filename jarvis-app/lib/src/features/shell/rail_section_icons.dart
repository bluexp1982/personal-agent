import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 「项目」标题行右端的三枚图标。
///
/// Material 里没有对应的字形：`search_rounded` 的把手更短、`tune` 是三行滑杆
/// （参考图只有两行）、`create_new_folder` 的加号画在文件夹里面（参考图在右上角，
/// 且文件夹的右上角是敞开的）。所以按高清参考图逐个描，共用同一套栅格与笔宽。
enum RailSectionGlyphKind { search, viewOptions, addProject }

/// 单色线性图标：24×24 栅格、2dp 描边、圆角端点，按 [size] 等比缩放。
class RailSectionGlyph extends StatelessWidget {
  const RailSectionGlyph({
    super.key,
    required this.kind,
    required this.color,
    this.size = 16,
  });

  final RailSectionGlyphKind kind;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _GlyphPainter(kind: kind, color: color),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({required this.kind, required this.color});

  final RailSectionGlyphKind kind;
  final Color color;

  static const double _grid = 24;
  static const double _strokeWidth = 2;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // 图形本身画在 24 格里、四周各留约 2 格空——与图标字体的内边距同构，
    // 所以这里的 `size` 等价于 `Icon(size: ...)`，不会比同尺寸的字体图标更大。
    canvas.scale(size.width / _grid);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (kind) {
      case RailSectionGlyphKind.search:
        _paintSearch(canvas, paint);
      case RailSectionGlyphKind.viewOptions:
        _paintViewOptions(canvas, paint);
      case RailSectionGlyphKind.addProject:
        _paintAddProject(canvas, paint);
    }

    canvas.restore();
  }

  /// 放大镜：一个圆 + 45° 的短把手，把手从圆周上长出来。
  void _paintSearch(Canvas canvas, Paint paint) {
    const center = Offset(10.0, 10.0);
    const radius = 7.8;
    canvas.drawCircle(center, radius, paint);
    final start = center + const Offset(radius, radius) * (1 / math.sqrt2);
    canvas.drawLine(start, const Offset(20.8, 20.8), paint);
  }

  /// 视图选项：两行滑杆，上行的旋钮偏右、下行的偏左。
  ///
  /// 线段在旋钮处断开而不是用底色盖住：图标要能放在任意底色上
  /// （侧栏半透明、行选中时的浅灰），填底色会露馅。
  void _paintViewOptions(Canvas canvas, Paint paint) {
    const knobRadius = 2.3;
    const gap = knobRadius + _strokeWidth / 2;
    const left = 2.6;
    const right = 21.4;

    for (final row in <({double y, double knobX})>[
      (y: 8.2, knobX: 15.0),
      (y: 15.8, knobX: 8.6),
    ]) {
      canvas.drawLine(
        Offset(left, row.y),
        Offset(row.knobX - gap, row.y),
        paint,
      );
      canvas.drawLine(
        Offset(row.knobX + gap, row.y),
        Offset(right, row.y),
        paint,
      );
      canvas.drawCircle(Offset(row.knobX, row.y), knobRadius, paint);
    }
  }

  /// 新建项目：右上角敞开的文件夹 + 一枚落在缺口处的小加号。
  void _paintAddProject(Canvas canvas, Paint paint) {
    // 文件夹：从敞口处逆时针描一圈到底部右侧（不闭合，右上角留给加号）。
    final folder = Path()
      ..moveTo(12.4, 7.2)
      ..lineTo(11.4, 5.8)
      ..lineTo(5.0, 5.8)
      ..quadraticBezierTo(3.4, 5.8, 3.4, 7.4)
      ..lineTo(3.4, 17.2)
      ..quadraticBezierTo(3.4, 18.8, 5.0, 18.8)
      ..lineTo(17.4, 18.8)
      ..quadraticBezierTo(19.0, 18.8, 19.0, 17.2)
      ..lineTo(19.0, 10.8);
    canvas.drawPath(folder, paint);

    // 加号：落在文件夹右上角的缺口里，上端与文件夹顶边齐平，右臂略探出文件夹外。
    canvas.drawLine(const Offset(14.4, 7.2), const Offset(19.8, 7.2), paint);
    canvas.drawLine(const Offset(17.1, 4.4), const Offset(17.1, 10.0), paint);
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) {
    return oldDelegate.kind != kind || oldDelegate.color != color;
  }
}
