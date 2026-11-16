import 'package:flutter/material.dart';

import 'shell_layout_state.dart';

/// 骨架级横线的 Key。测试用它断言"宽屏有这一层、窄屏没有"。
const Key kShellDividerLayerKey = Key('shell-divider-layer');

/// 骨架里所有分隔线共用的颜色。
///
/// 横线由 [ShellDividers] 画、竖线由 `ShellResizeHandle` 画，但颜色只能有一份：
/// 早先三处各写一个 alpha（0.35 / 0.4），同一条线在栏缝两端深浅不同，
/// 断口看着比实际还明显。
Color shellDividerColor(ColorScheme scheme) =>
    scheme.outlineVariant.withValues(alpha: 0.4);

/// 告诉子树「栏头横线已经由骨架层画了」。
///
/// 宽屏三栏的横线必须跨过 8dp 拖动条才连得上（[ShellDividers] 就是干这个的）；
/// 栏若还在自己的容器边缘画 `border.bottom`，那条线只能画到栏的宽度，交界处
/// 必然缺一段。窄屏没有这一层，栏内的 border 照旧由 `EmbeddedToolbar` 与
/// `ProjectPanel` 自己画。
class ShellDividerScope extends InheritedWidget {
  const ShellDividerScope({
    super.key,
    required this.active,
    required super.child,
  });

  /// 宽屏（骨架级横线生效）为 true；窄屏恒为 false。
  ///
  /// 用标志位而不是"有没有这个 InheritedWidget"，是为了让宽窄切换时
  /// 子树深度不变——多一层/少一层会把整棵 Element 重建掉。
  final bool active;

  /// 当前子树上方是否有骨架级分隔线层。
  static bool isActive(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellDividerScope>()?.active ??
      false;

  @override
  bool updateShouldNotify(ShellDividerScope oldWidget) =>
      oldWidget.active != active;
}

/// 宽屏骨架的横线层：**横向**分隔线只在这里画。
///
/// 竖线不在这里：它要跟悬停 / 拖拽联动（加粗转主色），住在 `ShellResizeHandle`
/// 里。横线没有交互态，放在骨架层反而能把 8dp 栏缝一起盖住，于是竖线与横线在
/// 拐角处必然相接，不再出现"横线在栏宽处收笔、离竖线还差 8dp"的缺口。
///
/// **这一层必须包住整个骨架**（左侧栏一起包），不能只包中栏：里面的坐标就是
/// 窗口坐标，[centerLeft] 才是"从窗口左缘算起"的那个值。只包中栏的话画布
/// x=0 已经在中栏左边，[centerLeft] 会被算两遍——横线整体右移一条栏宽。
///
/// 位置全部由几何推出，不猜像素：
/// - 栏头横线在 `y = kPaneHeaderHeight`（中栏工具栏与右栏标签栏同高），
///   从中栏左边界一直画到窗口右缘，把两条栏头线在栏缝处接成一条；
/// - 左栏底部账户行上方那条在最后一格（[kPaneHeaderHeight]）的上边缘，
///   从窗口左缘画到中栏左边界（含左栏右侧那条 8dp 缝）。
class ShellDividers extends StatelessWidget {
  const ShellDividers({
    super.key,
    required this.centerLeft,
    required this.footerVisible,
    this.enabled = true,
    required this.child,
  });

  /// 中栏左边界 = 左栏宽度 + 它右侧拖动条宽度。左栏收起时为 0。
  ///
  /// 它同时是左栏拖动条那条竖线的位置，所以横线从这里起笔就正好接上竖线。
  final double centerLeft;

  /// 左栏底部账户行上方那条横线是否存在。左栏收起时那一格跟着消失。
  final bool footerVisible;

  /// 是否画。窄屏骨架（顶部单列）没有三栏，也就不用这一层；标志位而不是
  /// 增删 widget，是为了让宽窄切换时下面的 Element 不换深度。
  final bool enabled;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ShellDividerScope(
      active: enabled,
      child: Stack(
        // passthrough：内容区照旧拿父级给的紧约束，这一层只是叠在上面。
        fit: StackFit.passthrough,
        children: <Widget>[
          child,
          if (enabled)
            // 纯装饰：不能让这一层吃掉拖动条与按钮的指针事件。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  key: kShellDividerLayerKey,
                  painter: _ShellDividerPainter(
                    centerLeft: centerLeft,
                    footerVisible: footerVisible,
                    color: shellDividerColor(scheme),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ShellDividerPainter extends CustomPainter {
  const _ShellDividerPainter({
    required this.centerLeft,
    required this.footerVisible,
    required this.color,
  });

  final double centerLeft;
  final bool footerVisible;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;

    // 栏头横线：中栏 + 右栏共一条。两栏的栏头都压在同一个 y 上，
    // 中间的 8dp 由这一段补上，视觉上才是连续的一条。
    canvas.drawRect(
      Rect.fromLTRB(
        centerLeft,
        kPaneHeaderHeight - kPaneHeaderBorderWidth,
        size.width,
        kPaneHeaderHeight,
      ),
      paint,
    );

    if (!footerVisible) {
      return;
    }

    // 「设置」行是左栏最后一格，线压在它上边缘；往右一直画到竖线上。
    final bottom = size.height - kPaneHeaderHeight;
    canvas.drawRect(
      Rect.fromLTRB(0, bottom - kPaneHeaderBorderWidth, centerLeft, bottom),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ShellDividerPainter oldDelegate) =>
      oldDelegate.centerLeft != centerLeft ||
      oldDelegate.footerVisible != footerVisible ||
      oldDelegate.color != color;
}
