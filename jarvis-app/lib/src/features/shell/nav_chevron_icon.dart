import 'package:flutter/material.dart';

/// 浏览器式的「后退 / 前进」箭头：一条两段折线，端点与拐角都收圆。
///
/// 不用 Material 的 `chevron_left`：那一族的描边偏粗，放进 14dp 的栏头里
/// 会比旁边的侧栏开合图标重一档。这里沿用 [SidebarToggleIcon] 的笔画比例
/// （线宽 = 边长 × 0.09），两枚图标在同一排里才是同一个视觉重量。
class NavChevronIcon extends StatelessWidget {
  const NavChevronIcon({
    super.key,
    required this.forward,
    this.size = 14,
    this.color,
  });

  /// true 指「前进」（>），false 指「后退」（<）。
  final bool forward;
  final double size;

  /// 不传时跟随 `IconTheme`：禁用色、深色栏头里的白字都走那一层。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved =
        color ?? IconTheme.of(context).color ?? scheme.onSurfaceVariant;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NavChevronPainter(color: resolved, forward: forward),
      ),
    );
  }
}

class _NavChevronPainter extends CustomPainter {
  const _NavChevronPainter({required this.color, required this.forward});

  final Color color;
  final bool forward;

  @override
  void paint(Canvas canvas, Size size) {
    // 与侧栏开合图标同一条比例：14dp 时约 1.26，和图标字体里
    // 最细那一档的笔画等重。
    final stroke = size.width * 0.09;
    final tipX = size.width * (forward ? 0.64 : 0.36);
    final tailX = size.width * (forward ? 0.40 : 0.60);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // 折线垂直居中、上下各留 0.22 的呼吸：贴满边会显得箭头比同排图标大。
    canvas.drawPath(
      Path()
        ..moveTo(tailX, size.height * 0.22)
        ..lineTo(tipX, size.height * 0.5)
        ..lineTo(tailX, size.height * 0.78),
      paint,
    );
  }

  @override
  bool shouldRepaint(_NavChevronPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.forward != forward;
}
