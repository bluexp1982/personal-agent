import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 虚化带贴哪条边：从这条边开始最浓，往对侧淡出。
enum EdgeDirection { top, bottom }

/// 贴边虚化带：一半是模糊、一半是淡底色，方向可翻转。
///
/// 上下各一条（顶部页头、底部导航），两条必须同源——模糊量、渐变停靠点、
/// 底色强度只要差一点，"上下呼应"就会变成"上下打架"。
///
/// 画法：
/// 1. 背景模糊：`ShaderMask` 用自贴边那侧的 alpha 渐变裁掉模糊层——贴边全糊、
///    另一端全清，所以看不到"模糊区"与"清晰区"之间的硬边；
/// 2. 淡底色：`scheme.surface` 从贴边那侧淡出，把糊掉的内容压成看得出轮廓的
///    色块。用 `scheme.surface` 是因为整窗渐变在 `kSurfaceTopTintStop` 之后
///    就是它，两者天然衔接，深浅主题与主题包自动跟随。
///
/// 只负责画，不管点击与尺寸：外面包 `IgnorePointer` 还是 `AbsorbPointer`、
/// 高度多少，由各自的调用方决定。
class EdgeFade extends StatelessWidget {
  const EdgeFade({
    super.key,
    required this.direction,
    required this.blur,
    this.fill,
    this.fillAlpha = 0.8,
    this.fillFromAlpha,
    this.fillStop = 0.62,
  });

  /// 从哪条边开始最浓。
  final EdgeDirection direction;

  /// 模糊量。上下两条用同一个值，观感才是同一块玻璃的两端。
  final ImageFilter blur;

  /// 淡底色。不传时用 `scheme.surface`。
  ///
  /// 顶部那条必须传"它背后那一层的颜色"（见 `appSurfaceTopColor`）：整窗渐变在
  /// 顶部是染过色的，用纯 `surface` 会在页头下沿压出一条更深的横带。
  final Color? fill;

  /// 贴边处的底色强度。
  final double fillAlpha;

  /// 贴边那一行自己的底色强度；不传时等于 [fillAlpha]。
  ///
  /// 顶部那条要传 0：它贴在"状态栏下沿"这种**背景正在变暗**的位置上，起点带
  /// 0.55 的填充会比自己身后的背景更亮，形成一条细横线（实测 39→43 的台阶）。
  /// 从 0 渐入、到 [fillStop] 处到峰值、最后淡出，三次都是连续的，边界处差值为 0。
  final double? fillFromAlpha;

  /// 过渡起点（占整条带高度的比例，自贴边那侧量）。
  final double fillStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = fill ?? scheme.surface;
    final startAlpha = fillFromAlpha ?? fillAlpha;
    final begin = direction == EdgeDirection.top
        ? Alignment.topCenter
        : Alignment.bottomCenter;
    final end = direction == EdgeDirection.top
        ? Alignment.bottomCenter
        : Alignment.topCenter;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: begin,
            end: end,
            // 纯黑只当遮罩用，不表达任何主题色。
            colors: const <Color>[Color(0xFF000000), Color(0x00000000)],
          ).createShader(rect),
          child: ClipRect(
            child: BackdropFilter(
              filter: blur,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: begin,
              end: end,
              colors: <Color>[
                color.withValues(alpha: startAlpha),
                color.withValues(alpha: fillAlpha * 0.45),
                color.withValues(alpha: 0),
              ],
              stops: <double>[0, fillStop, 1],
            ),
          ),
        ),
      ],
    );
  }
}
