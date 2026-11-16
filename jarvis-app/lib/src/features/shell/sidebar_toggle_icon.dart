import 'package:flutter/material.dart';

/// 侧栏显示/隐藏按钮的图标：圆角矩形轮廓 + 一条竖分隔线。
///
/// 不用 Material 的 `view_sidebar`：那个是"左栏实心填充"，
/// 收起态里长得像一个被选中的面板，和"点一下开合"的语义对不上。
/// 这枚图标自己画：只有 1px 级的线宽与一个圆角，几何简单，没必要引图片资源，
/// 也不受 Material Symbols 版本影响。
class SidebarToggleIcon extends StatelessWidget {
  const SidebarToggleIcon({
    super.key,
    this.size = 18,
    this.color,
    this.mirrored = false,
  });

  /// 默认 18；栏头里由调用方传入 `kPaneHeaderIconSize`（14），
  /// 与红绿灯直径同量级。
  final double size;

  /// 不传时跟随 `IconTheme`：按钮的禁用色、强调色都在那里。
  final Color? color;

  /// 分隔线画在右侧。右侧栏的入口用镜像版本：
  /// 同一枚图标换个朝向，一眼就能分清它管的是哪一边。
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved =
        color ?? IconTheme.of(context).color ?? scheme.onSurfaceVariant;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SidebarTogglePainter(color: resolved, mirrored: mirrored),
      ),
    );
  }
}

class _SidebarTogglePainter extends CustomPainter {
  const _SidebarTogglePainter({required this.color, required this.mirrored});

  final Color color;

  /// 分隔线靠右还是靠左。
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    // 线宽按边长取比例：20dp 时约 1.8，和自带图标集的视觉重量一致。
    final stroke = size.width * 0.09;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.22)),
      paint,
    );

    // 分隔线落在左（或右）三分之一处：太靠边会像描边，太靠中就成了"上下两栏"。
    final x = rect.left + rect.width * (mirrored ? 0.64 : 0.36);
    canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
  }

  @override
  bool shouldRepaint(_SidebarTogglePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.mirrored != mirrored;
}
