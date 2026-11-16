import 'package:flutter/material.dart';

/// 手机版页头里「按原型路径自绘」的四枚图标。
///
/// 原型的内联 SVG 是 24 视口的细描边（1.6 / 1.8），缩到 18dp 后线宽只有
/// 1.2 左右——Material 的同名图标（实心箭头、粗三点、短柄放大镜）都比它重，
/// 摆在 38dp 的玻璃圆钮里会显得糊。所以这四枚自己画，其余动作图标继续用
/// Material（刷新、设置、另存为、缩放、适配…），只是同样收到 18dp。
enum MobileTopBarGlyph {
  /// 返回：`M14.5 5 8 12l6.5 7`，stroke 1.6。
  back,

  /// 更多：三枚实心圆点（原型 `circle r=.7` + stroke 1.8）。
  more,

  /// 新建：`M12 5.5v13M5.5 12h13`，stroke 1.8。
  add,

  /// 搜索：`circle(11,11,6.5)` + `m16 16 4 4`，stroke 1.6。
  search,
}

/// 描边图标本体。尺寸按 24 视口等比缩放，圆头圆角。
class MobileTopBarIcon extends StatelessWidget {
  const MobileTopBarIcon({
    super.key,
    required this.glyph,
    required this.color,
    this.size = 18,
  });

  final MobileTopBarGlyph glyph;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MobileGlyphPainter(glyph: glyph, color: color),
        // 文案由按钮的 Tooltip / Semantics 提供，图标本身不重复念一遍。
        isComplex: false,
      ),
    );
  }
}

class _MobileGlyphPainter extends CustomPainter {
  const _MobileGlyphPainter({required this.glyph, required this.color});

  final MobileTopBarGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 原型路径按 24×24 画；这里按实际边长换算。
    final s = size.width / 24;
    final stroke = (glyph == MobileTopBarGlyph.more ||
            glyph == MobileTopBarGlyph.add
        ? 1.8
        : 1.6) *
        s;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (glyph) {
      case MobileTopBarGlyph.back:
        final path = Path()
          ..moveTo(14.5 * s, 5 * s)
          ..lineTo(8 * s, 12 * s)
          ..lineTo(14.5 * s, 19 * s);
        canvas.drawPath(path, paint);
      case MobileTopBarGlyph.more:
        // 原型是 r=0.7 的圆再加 1.8 描边，实心画出来直径约 3.2 个视口单位。
        final dot = Paint()..color = color;
        for (final x in <double>[6, 12, 18]) {
          canvas.drawCircle(Offset(x * s, 12 * s), 1.4 * s, dot);
        }
      case MobileTopBarGlyph.add:
        canvas.drawLine(Offset(12 * s, 5.5 * s), Offset(12 * s, 18.5 * s), paint);
        canvas.drawLine(Offset(5.5 * s, 12 * s), Offset(18.5 * s, 12 * s), paint);
      case MobileTopBarGlyph.search:
        canvas.drawCircle(Offset(11 * s, 11 * s), 6.5 * s, paint);
        canvas.drawLine(Offset(16 * s, 16 * s), Offset(20 * s, 20 * s), paint);
    }
  }

  @override
  bool shouldRepaint(_MobileGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
