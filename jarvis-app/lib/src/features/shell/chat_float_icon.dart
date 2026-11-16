import 'package:flutter/material.dart';

/// 「聊天浮窗」图标：一个圆角大框 + 左下角嵌着一个圆角小框，大框轮廓在
/// 小框处断开。
///
/// 不用 Material 的 `picture_in_picture_alt_outlined`：那一个是**小框在右下**
/// 且小框压在大框内侧，与参考图（小框探到左下、大框轮廓断开）不是一回事。
/// 这里按 24×24 栅格、2dp 描边自绘，与 `NewConversationIcon` /
/// `PanelFullscreenIcon` 共用同一套几何口径（`canvas.scale(size / 24)`），
/// 缩到栏头的 14dp 时线宽与旁边的字体图标一致，不会显得更重。
///
/// 颜色不自己猜：栏头那枚跟随 `IconTheme`，工具条里点亮时由调用方传主色。
class ChatFloatIcon extends StatelessWidget {
  const ChatFloatIcon({super.key, this.size = 16, this.color});

  /// 默认 16；栏头里由调用方传入 `kPaneHeaderIconSize`（14）。
  final double size;

  /// 不传时跟随 `IconTheme`：按钮的禁用色、强调色都在那里。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved =
        color ?? IconTheme.of(context).color ?? scheme.onSurfaceVariant;

    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _ChatFloatPainter(color: resolved)),
    );
  }
}

class _ChatFloatPainter extends CustomPainter {
  const _ChatFloatPainter({required this.color});

  final Color color;

  /// 参考图是 24 栅格的高清稿：图形四周各留约 2 格空。
  static const double _grid = 24;
  static const double _strokeWidth = 2;

  /// 大框的圆角与小框的圆角。大框的圆角明显更大，小框反而更方——
  /// 这个反差是参考图的形状特征，缩到 14dp 也能读出来。
  static const double _bigRadius = 3.5;
  static const double _smallRadius = 1.6;

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

    // 大框：从左边缘（小框上沿）起笔，顺时针绕过三个角，底边收在小框右侧。
    // 缺口两处各留约 1 格：太小会糊成一块，太大会读成"两个互不相干的框"。
    final big = Path()
      // 左边缘停在小框上沿稍上一点：再往下画会和小框的左边共线重叠，
      // 恰好压在小框上边缘上又会把交界处糊成一个圆点。
      ..moveTo(5, 9.4)
      ..lineTo(5, 6.5)
      ..arcToPoint(
        const Offset(8.5, 3),
        radius: const Radius.circular(_bigRadius),
      )
      ..lineTo(17.5, 3)
      ..arcToPoint(
        const Offset(21, 6.5),
        radius: const Radius.circular(_bigRadius),
      )
      ..lineTo(21, 14.5)
      ..arcToPoint(
        const Offset(17.5, 18),
        radius: const Radius.circular(_bigRadius),
      )
      ..lineTo(12.6, 18);

    // 小框要留出能看见的空隙：24 栅格、2dp 描边下，框小于 7 格就会被描边
    // 吃掉整块内部，缩到 14dp 只剩一坨实心。宽高比照参考图取 1.3:1。
    final small = RRect.fromLTRBR(
      4.2,
      10.5,
      11.8,
      16.8,
      const Radius.circular(_smallRadius),
    );

    canvas
      ..drawPath(big, paint)
      ..drawRRect(small, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(_ChatFloatPainter oldDelegate) =>
      oldDelegate.color != color;
}
