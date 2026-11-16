import 'package:flutter/widgets.dart';

/// 可拖动内容的光标：悬停是「抓手」，按住拖动时是「抓紧」。
///
/// 只在内容真的拖得动时才用（图片放大后、PDF 内容超出视口）：
/// 整页都挂抓手会让人以为"点什么都能拖"，拖动一次没反应才发现不是。
///
/// 判据由调用方给（[enabled]），这里只负责指针按下 / 抬起的计数——
/// 多指捏合时会有多个指针，按"还有没有手指按着"算才不会中途弹回抓手。
///
/// 用 `Listener` 而不是 `GestureDetector`：它不参与手势竞技，
/// 不会从 `InteractiveViewer` 或 pdfrx 手里抢走拖动。
const Key kPreviewPanCursorKey = Key('preview-pan-cursor');

class PanCursorArea extends StatefulWidget {
  const PanCursorArea({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// 内容此刻是否拖得动。`false` 时保持系统默认光标。
  final bool enabled;

  @override
  State<PanCursorArea> createState() => _PanCursorAreaState();
}

class _PanCursorAreaState extends State<PanCursorArea> {
  int _pointers = 0;

  void _down(PointerDownEvent event) => setState(() => _pointers++);

  void _up(PointerEvent event) {
    if (_pointers == 0) {
      return;
    }
    setState(() => _pointers--);
  }

  @override
  Widget build(BuildContext context) {
    final pressing = _pointers > 0;
    return MouseRegion(
      key: kPreviewPanCursorKey,
      cursor: !widget.enabled
          ? MouseCursor.defer
          : pressing
          ? SystemMouseCursors.grabbing
          : SystemMouseCursors.grab,
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: widget.child,
      ),
    );
  }
}
