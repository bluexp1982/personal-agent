import 'package:flutter/material.dart';

/// 底部导航标签图标的边长。
///
/// 24 按参考 App 的视觉重量定：它的实心图标可见约 18.8pt，本 App 是描边
/// 图形、图形只占画布的约 74.5%，22 的画布只显出 16.4，偏小偏细。
/// 升到 24 后可见约 17.9，配合 2 的画布间距，视觉空隙才收得到参考的 6.3。
/// 不能再大：55 高的选中底里「24 + 2 + 文字」已经占 38.6，上下只剩 8.2。
const double kNarrowTabIconSize = 24;

/// 底部导航的五枚图标。
///
/// 全部按手机端原型里的内联 SVG 路径自绘（viewBox 24 → 24dp 等比缩放）：
/// 那五枚的转角圆率、气泡尾巴与星芒比例在 Material Symbols 里没有对应形，
/// 拿相近的图标凑会一眼看出是两套东西。
enum NarrowGlyph { agent, recordings, call, messages, profile }

/// 描边图标本体。
///
/// 线宽取原型值：未选中 1.5、选中 1.9（viewBox 单位，按边长缩放），
/// 圆头圆角——与 `SidebarToggleIcon` 同一套描边质感。
class NarrowTabIcon extends StatelessWidget {
  const NarrowTabIcon({
    super.key,
    required this.glyph,
    required this.color,
    this.selected = false,
    this.size = kNarrowTabIconSize,
  });

  final NarrowGlyph glyph;
  final Color color;

  /// 选中时描边加粗。原型里就是靠这一点让"当前在哪"在不看文字时也成立。
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GlyphPainter(
          glyph: glyph,
          color: color,
          selected: selected,
        ),
        // 图标本身不带语义：文案就在下面，读屏再念一遍只会重复。
        isComplex: false,
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.glyph,
    required this.color,
    required this.selected,
  });

  final NarrowGlyph glyph;
  final Color color;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    // 原型路径按 24×24 画，这里统一换算成实际边长。
    final s = size.width / 24;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (selected ? 1.9 : 1.5) * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (glyph) {
      case NarrowGlyph.agent:
        _paintAgent(canvas, s, paint);
      case NarrowGlyph.recordings:
        _paintRecordings(canvas, s, paint);
      case NarrowGlyph.call:
        _paintCall(canvas, s, paint);
      case NarrowGlyph.messages:
        _paintMessages(canvas, s, paint);
      case NarrowGlyph.profile:
        _paintProfile(canvas, s, paint);
    }
  }

  /// Agent：四角星芒（`M12 3.2 13.9 9.1 19.8 11 …`）。
  void _paintAgent(Canvas canvas, double s, Paint paint) {
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

  /// 记录：带三行文字的单据，末行短一截。
  void _paintRecordings(Canvas canvas, double s, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(5 * s, 3.6 * s, 14 * s, 16.8 * s),
        Radius.circular(2.5 * s),
      ),
      paint,
    );
    const lines = <(double, double)>[(8.4, 15.4), (12, 15.4), (15.6, 12.8)];
    for (final (y, right) in lines) {
      canvas.drawLine(
        Offset(8.6 * s, y * s),
        Offset(right * s, y * s),
        paint,
      );
    }
  }

  /// 通话：麦克风（胶囊头 + 下方 U 形支架 + 竖杆）。
  ///
  /// 原型这一屏是从底部导航里移除的，导航没有给过通话图形；
  /// 取通话页里那颗麦克风的路径，与页内控制键同形。
  void _paintCall(Canvas canvas, double s, Paint paint) {
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

  /// 消息：圆角对话气泡，左下有朝下的尾巴。
  void _paintMessages(Canvas canvas, double s, Paint paint) {
    final radius = Radius.circular(2 * s);
    final path = Path()
      ..moveTo(4.5 * s, 19 * s)
      ..lineTo(4.5 * s, 6 * s)
      ..arcToPoint(Offset(6.5 * s, 4 * s), radius: radius)
      ..lineTo(18 * s, 4 * s)
      ..arcToPoint(Offset(20 * s, 6 * s), radius: radius)
      ..lineTo(20 * s, 13.5 * s)
      ..arcToPoint(Offset(18 * s, 15.5 * s), radius: radius)
      ..lineTo(8.5 * s, 15.5 * s)
      ..close();
    canvas.drawPath(path, paint);
  }

  /// 我的：头肩人形。
  void _paintProfile(Canvas canvas, double s, Paint paint) {
    canvas.drawCircle(Offset(12 * s, 8.6 * s), 3.6 * s, paint);
    final shoulders = Path()
      ..moveTo(5.4 * s, 19.6 * s)
      ..cubicTo(6.6 * s, 16.4 * s, 9.1 * s, 14.7 * s, 12 * s, 14.7 * s)
      ..cubicTo(14.9 * s, 14.7 * s, 17.4 * s, 16.4 * s, 18.6 * s, 19.6 * s);
    canvas.drawPath(shoulders, paint);
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.selected != selected;
}
