import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';

/// 项目行首的文件夹图标：收起 / 展开 / 选中三态。
///
/// 不用 Material 的 `folder_*`：那几枚在 16dp 下轮廓几乎一样，看不出状态；
/// 这里按高清参考图重描：收起是"页签 + 盒子里一道横线"，展开是"合起的后板 +
/// 向右下探出的前盖"，选中只是整体换成项目强调色（形状随开合，不另起一套）。
class ProjectFolderIcon extends StatelessWidget {
  const ProjectFolderIcon({
    super.key,
    required this.size,
    required this.expanded,
    required this.selected,
  });

  final double size;
  final bool expanded;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // 选中跟项目强调色：与项目卡片、计数胶囊、导航选中态同一档，
    // 换主题 / 换主题包时不会剩下另一种颜色的异物。
    final selectedColor = palette.accent.projectStart;
    final color = selected ? selectedColor : palette.text.tertiary;

    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _ProjectFolderPainter(
          expanded: expanded,
          stroke: color,
          // 前盖那层浅色：选中是强调色的淡底，未选中是极淡的灰（参考图里也能
          // 看出前盖比后板亮一档）。
          fill: selected
              ? selectedColor.withValues(alpha: 0.20)
              : color.withValues(alpha: 0.10),
        ),
      ),
    );
  }
}

/// 在 24×24 的设计栅格里描图标，再整体缩放到目标尺寸。
///
/// 坐标是从参考图（544×560 的高清截图）量出来再归一化的：
/// 图标整体比正方形略宽，页签顶边更靠上，右侧前盖比后板多探出约 1 个单位。
class _ProjectFolderPainter extends CustomPainter {
  const _ProjectFolderPainter({
    required this.expanded,
    required this.stroke,
    required this.fill,
  });

  final bool expanded;
  final Color stroke;
  final Color fill;

  static const double _grid = 24;
  static const double _strokeWidth = 2.0;

  static const double _left = 2.2;
  static const double _right = 21.2;
  static const double _tabTop = 1.8;
  static const double _top = 5.2;
  static const double _bottom = 21.4;

  /// 页签顶边的终点、斜边落到后板顶边的那一点。
  static const double _tabEnd = 10.2;
  static const double _tabStep = 13.2;

  /// 前盖上沿，以及它比后板多探出的那一点右边缘。
  static const double _flapTop = 10.8;
  static const double _flapRight = 22.6;

  static const double _radius = 2.6;

  /// 收起态盒子里那道横线（参考图里它在中线略上方，短于整宽）。
  static const double _seamY = 11.4;
  static const double _seamLeft = 7.6;
  static const double _seamRight = 17.8;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _grid);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = stroke;

    if (expanded) {
      // 后板只画到前盖上沿：下半个轮廓由前盖提供，不会出现两条压在一起的边。
      canvas.drawPath(_backPanel(), paint);
      final flap = _flap();
      canvas.drawPath(flap, Paint()..color = fill);
      canvas.drawPath(flap, paint);
    } else {
      final body = _closedBody();
      canvas.drawPath(body, paint);
      canvas.drawLine(
        const Offset(_seamLeft, _seamY),
        const Offset(_seamRight, _seamY),
        paint,
      );
    }

    canvas.restore();
  }

  /// 收起态：一个带页签的圆角方盒。
  Path _closedBody() {
    return Path()
      ..moveTo(_left, _bottom - _radius)
      ..lineTo(_left, _tabTop + _radius)
      ..quadraticBezierTo(_left, _tabTop, _left + _radius, _tabTop)
      ..lineTo(_tabEnd, _tabTop)
      ..lineTo(_tabStep, _top)
      ..lineTo(_right - _radius, _top)
      ..quadraticBezierTo(_right, _top, _right, _top + _radius)
      ..lineTo(_right, _bottom - _radius)
      ..quadraticBezierTo(_right, _bottom, _right - _radius, _bottom)
      ..lineTo(_left + _radius, _bottom)
      ..quadraticBezierTo(_left, _bottom, _left, _bottom - _radius)
      ..close();
  }

  /// 展开态的后板：从下往上走一条开口的路径，止于前盖上沿。
  Path _backPanel() {
    return Path()
      ..moveTo(_left, _flapTop)
      ..lineTo(_left, _tabTop + _radius)
      ..quadraticBezierTo(_left, _tabTop, _left + _radius, _tabTop)
      ..lineTo(_tabEnd, _tabTop)
      ..lineTo(_tabStep, _top)
      ..lineTo(_right - _radius, _top)
      ..quadraticBezierTo(_right, _top, _right, _top + _radius)
      ..lineTo(_right, _flapTop);
  }

  /// 展开态的前盖：贴着后板左侧、向右下探出一截的圆角面板。
  Path _flap() {
    return Path()
      ..moveTo(_left, _bottom - _radius)
      ..lineTo(_left, _flapTop + _radius)
      ..quadraticBezierTo(_left, _flapTop, _left + _radius, _flapTop)
      ..lineTo(_flapRight - _radius, _flapTop)
      ..quadraticBezierTo(_flapRight, _flapTop, _flapRight, _flapTop + _radius)
      ..lineTo(_flapRight, _bottom - _radius)
      ..quadraticBezierTo(_flapRight, _bottom, _flapRight - _radius, _bottom)
      ..lineTo(_left + _radius, _bottom)
      ..quadraticBezierTo(_left, _bottom, _left, _bottom - _radius)
      ..close();
  }

  @override
  bool shouldRepaint(_ProjectFolderPainter oldDelegate) {
    return oldDelegate.expanded != expanded ||
        oldDelegate.stroke != stroke ||
        oldDelegate.fill != fill;
  }
}
