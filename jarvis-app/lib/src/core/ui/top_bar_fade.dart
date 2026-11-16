import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../design/app_palette.dart';
import '../design/app_surface.dart';
import 'edge_fade.dart';
import 'mobile_top_bar.dart';
import 'shell_insets.dart';

/// 顶部虚化带的 Key（测试用来确认"这一层在"）。
const Key kTopFadeKey = Key('narrow-top-fade');

/// 越过页头下沿再淡出的一截：边界才没有硬线。
const double kTopFadeTail = 18;

/// 顶部虚化带的总高度：页头本体 + 延伸段。
const double kTopFadeHeight = kMobileTopBarMinHeight + kTopFadeTail;

/// 顶部虚化带的模糊量。
///
/// 与底部虚化带（22）同值：上下两端是同一块玻璃的两头，模糊量不同会立刻被看出来。
final ImageFilter _topFadeBlur = ImageFilter.blur(sigmaX: 22, sigmaY: 22);

/// 页头背后的虚化带：贴在窗口上沿，往下淡出。
///
/// 挂法很讲究：它必须画在**页面 body 之上、Scaffold 的 appBar 之下**——所以是
/// `AppPageScaffold` 把 body 包进 `Stack` 后叠在这里，而不是塞进 `AppBar.flexibleSpace`
/// （那一层与 body 不在同一个合成层，实测糊不到内容）。标题和按钮属于 appBar，
/// 画在它上面，保持清晰。
///
/// 点击分流：只有页头那 54 吸收点击（body 延伸到页头之后，藏在页头底下的卡片
/// 不该被点到）；往下延伸的淡出段不拦，内容照常可点。
class TopBarFade extends StatelessWidget {
  const TopBarFade({super.key, this.height = kTopFadeHeight, this.topInset});

  /// 整条带的高度。默认 = 页头 + 延伸段；智能体页的页头由外壳画、高度固定，
  /// 那里传 54 就够。
  final double height;

  /// 带子上沿距**窗口顶**的距离，用于算填充色取渐变上的哪一刻。
  ///
  /// 不传时读 `ShellInsets`（骨架内页面，`SafeArea` 已把 `padding.top` 清零，
  /// 只能靠骨架挂下来的值）。push 上来的整页不在骨架里，读不到那个 scope，
  /// 由 `AppPageScaffold` 按 `MediaQuery.padding.top` 显式传进来。
  final double? topInset;

  @override
  Widget build(BuildContext context) {
    // 带子上沿在整窗里的位置：SafeArea 把 padding / viewPadding 一起清零了，
    // 只能读骨架挂下来的那个值（见 `ShellInsets`），或由宿主直接给。
    final windowHeight = MediaQuery.sizeOf(context).height;
    final inset = topInset ?? ShellInsets.topOf(context);
    final fraction = windowHeight <= 0
        ? 0.0
        : (inset / windowHeight).clamp(0.0, 1.0);

    return SizedBox(
      key: kTopFadeKey,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          EdgeFade(
            direction: EdgeDirection.top,
            blur: _topFadeBlur,
            // 填充色取**带子上沿那一刻**的渐变色，而不是窗口最顶色：
            // 顶端色更亮，压在已经暗了一档的背景上会抬出 2~3 个亮度，
            // 在带子上沿留下一条细横线（实测 39→43 的台阶）。
            // 同色之后再淡出，边界两侧差值为 0，与 alpha 无关。
            fill: appSurfaceColorAt(
              AppPalette.of(context),
              Theme.of(context).colorScheme,
              fraction,
            ),
            // 起点透明、中段最浓：带子上沿与背景颜色即使有残差也乘 0，
            // 不会画出第二条线；下沿本来就淡出到 0。
            fillAlpha: 0.75,
            fillFromAlpha: 0,
          ),
          Align(
            alignment: Alignment.topCenter,
            // 页头那一段吸收点击；高度取页头本体，不跟着延伸段变。
            child: SizedBox(
              height: kMobileTopBarMinHeight,
              width: double.infinity,
              child: AbsorbPointer(child: SizedBox.expand()),
            ),
          ),
        ],
      ),
    );
  }
}
