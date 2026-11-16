import 'package:flutter/material.dart';

/// 通话页用到的自绘图形。
///
/// 全部按手机端原型里的内联 SVG 路径描出来（viewBox 24 → 实际边长等比缩放）：
/// 情景四宫格、下箭头、麦克风、静音麦克风、关摄像头、挂断与环心星芒，
/// 在 Material Symbols 里都没有转角与笔画比例都一致的对应形，拿相近的图标
/// 凑会一眼看出是两套东西（与底部导航那五枚同一套描边质感）。
enum CallGlyph { scenario, chevron, mic, micOff, cameraOff, hangUp, sparkle }

/// 描边图标本体。
///
/// 线宽按原型：普通控件 1.6、挂断 1.8；数值是 viewBox 单位，绘制时按边长缩放。
class CallIcon extends StatelessWidget {
  const CallIcon({
    super.key,
    required this.glyph,
    required this.color,
    this.size = 22,
    this.strokeWidth = 1.6,
  });

  final CallGlyph glyph;
  final Color color;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CallGlyphPainter(
          glyph: glyph,
          color: color,
          strokeWidth: strokeWidth,
        ),
        // 图标本身不带语义：按钮外层会给 Tooltip / Semantics。
        isComplex: false,
      ),
    );
  }
}

class _CallGlyphPainter extends CustomPainter {
  const _CallGlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeWidth,
  });

  final CallGlyph glyph;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (glyph) {
      case CallGlyph.scenario:
        _paintScenario(canvas, s, paint);
      case CallGlyph.chevron:
        _paintChevron(canvas, s, paint);
      case CallGlyph.mic:
        _paintMic(canvas, s, paint);
      case CallGlyph.micOff:
        _paintMic(canvas, s, paint);
        _paintSlash(canvas, s, paint);
      case CallGlyph.cameraOff:
        _paintCamera(canvas, s, paint);
        _paintSlash(canvas, s, paint);
      case CallGlyph.hangUp:
        _paintHangUp(canvas, s, paint);
      case CallGlyph.sparkle:
        _paintSparkle(canvas, s, paint);
    }
  }

  /// 情景：2×2 四个圆角方块。
  void _paintScenario(Canvas canvas, double s, Paint paint) {
    const cells = <(double, double)>[
      (4, 4),
      (13.5, 4),
      (4, 13.5),
      (13.5, 13.5),
    ];
    for (final (x, y) in cells) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x * s, y * s, 6.5 * s, 6.5 * s),
          Radius.circular(1.6 * s),
        ),
        paint,
      );
    }
  }

  /// 下箭头。
  void _paintChevron(Canvas canvas, double s, Paint paint) {
    final path = Path()
      ..moveTo(6 * s, 9.5 * s)
      ..lineTo(12 * s, 15.5 * s)
      ..lineTo(18 * s, 9.5 * s);
    canvas.drawPath(path, paint);
  }

  /// 麦克风：胶囊头 + 下方 U 形支架 + 竖杆。
  void _paintMic(Canvas canvas, double s, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(9.5 * s, 3.2 * s, 5 * s, 9.6 * s),
        Radius.circular(2.5 * s),
      ),
      paint,
    );
    final cradle = Path()
      ..moveTo(6.2 * s, 11 * s)
      ..arcToPoint(
        Offset(17.8 * s, 11 * s),
        radius: Radius.circular(5.8 * s),
        clockwise: false,
      );
    canvas.drawPath(cradle, paint);
    canvas.drawLine(
      Offset(12 * s, 16.8 * s),
      Offset(12 * s, 20.8 * s),
      paint,
    );
  }

  /// 关摄像头：机身 + 右侧镜头支架。
  void _paintCamera(Canvas canvas, double s, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(3.2 * s, 7 * s, 11 * s, 10 * s),
        Radius.circular(2.4 * s),
      ),
      paint,
    );
    final lens = Path()
      ..moveTo(14.2 * s, 11 * s)
      ..lineTo(20.2 * s, 8 * s)
      ..lineTo(20.2 * s, 16 * s)
      ..lineTo(14.2 * s, 13 * s);
    canvas.drawPath(lens, paint);
  }

  /// 静音 / 关闭的斜杠。
  void _paintSlash(Canvas canvas, double s, Paint paint) {
    canvas.drawLine(Offset(4.5 * s, 4.5 * s), Offset(19.5 * s, 19.5 * s), paint);
  }

  /// 挂断：X。
  void _paintHangUp(Canvas canvas, double s, Paint paint) {
    canvas.drawLine(Offset(6 * s, 6 * s), Offset(18 * s, 18 * s), paint);
    canvas.drawLine(Offset(18 * s, 6 * s), Offset(6 * s, 18 * s), paint);
  }

  /// 环心的星芒（与底部导航 Agent 图标同一枚形）。
  void _paintSparkle(Canvas canvas, double s, Paint paint) {
    final path = Path()
      ..moveTo(12 * s, 3.2 * s)
      ..lineTo(13.9 * s, 9.1 * s)
      ..lineTo(19.8 * s, 11 * s)
      ..lineTo(13.9 * s, 12.9 * s)
      ..lineTo(12 * s, 18.8 * s)
      ..lineTo(10.1 * s, 12.9 * s)
      ..lineTo(4.2 * s, 11 * s)
      ..lineTo(10.1 * s, 9.1 * s)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CallGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
