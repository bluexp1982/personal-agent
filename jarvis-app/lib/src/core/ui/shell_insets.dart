import 'package:flutter/widgets.dart';

/// 骨架的边距事实：内容区离窗口顶端有多远。
///
/// 为什么需要它：`SafeArea` 会把 `MediaQuery.padding` **和** `viewPadding` 一起清零
/// （见 Flutter 的 `MediaQueryData.removePadding`），所以页头背后那条虚化带在
/// SafeArea 之内拿不到"自己离窗口顶有多远"，也就没法算出它上沿对应的背景色。
/// 骨架在外层量一次、挂在这里，带子直接读。
class ShellInsets extends InheritedWidget {
  const ShellInsets({super.key, required this.top, required super.child});

  /// 内容区顶边到窗口顶边的距离（手机上是状态栏高度，桌面是 0）。
  final double top;

  /// 读不到就返回 0：非骨架内的用法（弹层、独立测试）按"贴窗口顶"处理。
  static double topOf(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<ShellInsets>();
    return scope?.top ?? 0;
  }

  @override
  bool updateShouldNotify(ShellInsets oldWidget) => oldWidget.top != top;
}
