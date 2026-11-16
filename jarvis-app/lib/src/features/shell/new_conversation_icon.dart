import 'package:flutter/material.dart';

/// 「新建会话」的图标：圆形气泡 + 左下角的尾巴 + 圆心一枚加号。
///
/// 不用 Material 的 `add_comment_outlined`：那个是**圆角矩形**气泡、加号偏左上，
/// 与参考图不是一回事。这里按 24×24 栅格、2dp 描边自绘，与 `RailSectionGlyph`
/// / `SidebarToggleIcon` 共用同一套几何口径（等比缩放到 [size]，等价于
/// `Icon(size:)`，不会比同尺寸的字体图标更大）。
///
/// 颜色不自己猜：侧栏那枚在禁用时要换成 `text.disabled`，栏头那枚要跟随
/// `IconTheme` 的禁用色，都交给调用方。
class NewConversationIcon extends StatelessWidget {
  const NewConversationIcon({super.key, this.size = 16, this.color});

  final double size;

  /// 不传时跟随 `IconTheme`：按钮的禁用色、强调色都在那里。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved =
        color ??
        IconTheme.of(context).color ??
        theme.colorScheme.onSurfaceVariant;

    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _NewConversationPainter(color: resolved)),
    );
  }
}

class _NewConversationPainter extends CustomPainter {
  const _NewConversationPainter({required this.color});

  final Color color;

  /// 参考图是 24 栅格的高清稿：图形四周各留约 2 格空，
  /// 与图标字体的内边距同构。
  static const double _grid = 24;
  static const double _strokeWidth = 2;

  /// 气泡圆：圆心在栅格正中，半径 9（外沿 10，正好贴住 24 格的两条边）。
  static const Offset _center = Offset(12, 12);
  static const double _radius = 9;

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

    _paintBubble(canvas, paint);

    // 加号：落在圆心，两臂各 4 格——占内圆直径的一半，与参考图的比例一致。
    canvas.drawLine(const Offset(8, 12), const Offset(16, 12), paint);
    canvas.drawLine(const Offset(12, 8), const Offset(12, 16), paint);

    canvas.restore();
  }

  /// 气泡轮廓：一条闭合路径。
  ///
  /// 从尾巴尖 (2,22) 起笔，沿底边接到圆周上的 (7.9,20)，再绕过大半圈到左下的
  /// (4,16.1)，最后由 `close()` 收回尾巴尖。尾巴不是另画一条线：
  /// 参考图里气泡底边本身就是尾巴的下沿，分开画会在接头处留一道断口。
  void _paintBubble(Canvas canvas, Paint paint) {
    // 两个接点相对圆心的角度（弧度，屏幕坐标 y 向下为正）：
    // (7.9, 20) ≈ 2.044， (4, 16.1) ≈ 2.665，中间那一小段就是留给尾巴的缺口。
    const startAngle = 2.044;
    const sweep = -5.662;

    final bubble = Path()
      ..moveTo(2, 22)
      ..lineTo(7.9, 20)
      ..arcTo(
        Rect.fromCircle(center: _center, radius: _radius),
        startAngle,
        sweep,
        false,
      )
      ..close();
    canvas.drawPath(bubble, paint);
  }

  @override
  bool shouldRepaint(_NewConversationPainter oldDelegate) =>
      oldDelegate.color != color;
}
