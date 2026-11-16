import 'package:flutter/material.dart';

/// 右侧栏工具条里的全屏按钮图标：对角两段括号（照 Codex 的标签条）。
///
/// 两态都是同一条对角线上的两段直角，只把拐点挪了个位置：
/// - 未全屏（进入全屏）：拐点落在方框的右上 / 左下角上，臂沿着边往内走，
///   读到的是"把框往外撑开"；
/// - 已全屏（退出全屏）：拐点挪到靠近中心那一侧，臂朝外伸到边角，
///   读到的是"把框收回来"。
///
/// 尺寸、线宽、方框大小两态完全一致，切状态时只有笔画方向变。
class PanelFullscreenIcon extends StatelessWidget {
  const PanelFullscreenIcon({
    super.key,
    this.size = 18,
    this.color,
    this.fullscreen = false,
  });

  /// 默认 18；栏头里由调用方传入 `kPaneHeaderIconSize`（14），
  /// 与同排的开合图标同量级。
  final double size;

  /// 不传时跟随 `IconTheme`：按钮的禁用色、强调色都在那里。
  final Color? color;

  /// 当前是否已全屏。已全屏时画"收回"的那一版。
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved =
        color ?? IconTheme.of(context).color ?? scheme.onSurfaceVariant;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _PanelFullscreenPainter(
          color: resolved,
          fullscreen: fullscreen,
        ),
      ),
    );
  }
}

class _PanelFullscreenPainter extends CustomPainter {
  const _PanelFullscreenPainter({
    required this.color,
    required this.fullscreen,
  });

  final Color color;

  /// 已全屏：拐点在内、臂朝外的那一版。
  final bool fullscreen;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    // 线宽按边长取比例：与侧栏开合图标同一口径（14dp 时约 1.4）。
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = side * 0.1
      // 截图里的笔画是方头、直角，不带圆角——14dp 上这一点决定了"像图标"
      // 还是"像随手画的线"。
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // 括号围出的方框不顶满画布：字形本身比图标格小一圈，
    // 缩进一点才不会在栏头里显得比旁边的开合图标更粗更挤。
    final span = side * 0.74;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: span,
      height: span,
    );

    if (fullscreen) {
      // 拐点离两条边各四成：臂正好够到边角，两段之间留出斜向空档。
      final k = rect.shortestSide * 0.4;
      canvas
        ..drawPath(
          Path()
            ..moveTo(rect.right, rect.top + k)
            ..lineTo(rect.right - k, rect.top + k)
            ..lineTo(rect.right - k, rect.top),
          paint,
        )
        ..drawPath(
          Path()
            ..moveTo(rect.left, rect.bottom - k)
            ..lineTo(rect.left + k, rect.bottom - k)
            ..lineTo(rect.left + k, rect.bottom),
          paint,
        );
    } else {
      // 拐点落在角上，臂走半条边：两段括号的臂尖在中间相对。
      final arm = rect.shortestSide * 0.5;
      canvas
        ..drawPath(
          Path()
            ..moveTo(rect.right - arm, rect.top)
            ..lineTo(rect.right, rect.top)
            ..lineTo(rect.right, rect.top + arm),
          paint,
        )
        ..drawPath(
          Path()
            ..moveTo(rect.left + arm, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..lineTo(rect.left, rect.bottom - arm),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(_PanelFullscreenPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.fullscreen != fullscreen;
}
