import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/app_palette.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/shell_layout_state.dart';

/// 消息流里的复制按钮：回答底部的元信息行、代码块表头共用同一枚。
///
/// 点击后图标切成对勾、1.2 秒后复原，并弹一句「已复制」——
/// 复制是"点完就该有反馈"的动作，等下一帧刷新太慢。
class MessageCopyButton extends StatefulWidget {
  const MessageCopyButton({super.key, required this.text});

  final String text;

  @override
  State<MessageCopyButton> createState() => _MessageCopyButtonState();
}

class _MessageCopyButtonState extends State<MessageCopyButton> {
  bool _copied = false;
  Timer? _reset;

  /// 与栏头那批图标按钮同一套：命中区 24、8dp 圆角方形悬停底。
  ///
  /// 原先是一枚 22 见方、悬停成正圆的紧凑小按钮；它和代码块表头、消息元信息行
  /// 同屏出现，规格不一致时一眼就能看出来。
  static final ButtonStyle _copyButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) {
      return;
    }

    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });

    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).message;

    return IconButton(
      tooltip: '复制',
      onPressed: _copy,
      style: _copyButtonStyle,
      iconSize: kPaneHeaderIconSize,
      color: palette.meta,
      // 自绘的双空框字形不吃 `iconSize`，尺寸要显式给；对勾那枚走 IconTheme。
      icon: _copied
          ? const Icon(Icons.check_rounded)
          : CopyGlyph(size: kPaneHeaderIconSize, color: palette.meta),
    );
  }
}

/// "复制"字形：两个空心圆角方框错位叠放。
///
/// 不用 Material 的 copy 图标：它是一笔实心/半实心的字形，与参考图那种
/// 细线双空心框差得明显。字形规模很小，直接画反而比找图标更可控，
/// 也不受各平台图标字体版本影响。
class CopyGlyph extends StatelessWidget {
  const CopyGlyph({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _CopyGlyphPainter(color),
    );
  }
}

class _CopyGlyphPainter extends CustomPainter {
  const _CopyGlyphPainter(this.color);

  final Color color;

  /// 归一化坐标（相对边长）：前框在左下，后框在右上。
  static const double _box = 0.58;
  static const double _frontLeft = 0.05;
  static const double _frontTop = 0.33;
  static const double _backLeft = 0.33;
  static const double _backTop = 0.05;
  static const double _corner = 0.16;

  /// 后框被前框"挡住"的位置留一道缝，两框叠在一起才不糊成一团。
  static const double _gap = 0.07;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = size.shortestSide;
    if (edge <= 0) {
      return;
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = edge / 13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final corner = Radius.circular(edge * _corner);
    final left = edge * _backLeft;
    final top = edge * _backTop;
    final right = left + edge * _box;
    final bottom = top + edge * _box;
    final frontTop = edge * _frontTop;
    final frontRight = edge * (_frontLeft + _box);
    final radius = edge * _corner;

    // 后框只画露在外面的部分：左边一小段 → 左上角 → 上边 → 右上角 →
    // 右边 → 右下角 → 底边收到前框右侧的缺口处。
    final back = Path()
      ..moveTo(left, frontTop - edge * _gap)
      ..lineTo(left, top + radius)
      ..arcToPoint(Offset(left + radius, top), radius: corner)
      ..lineTo(right - radius, top)
      ..arcToPoint(Offset(right, top + radius), radius: corner)
      ..lineTo(right, bottom - radius)
      ..arcToPoint(Offset(right - radius, bottom), radius: corner)
      ..lineTo(frontRight + edge * _gap, bottom);
    canvas.drawPath(back, paint);

    final front = RRect.fromLTRBAndCorners(
      edge * _frontLeft,
      frontTop,
      frontRight,
      frontTop + edge * _box,
      topLeft: corner,
      topRight: corner,
      bottomLeft: corner,
      bottomRight: corner,
    );
    canvas.drawRRect(front, paint);
  }

  @override
  bool shouldRepaint(_CopyGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}
