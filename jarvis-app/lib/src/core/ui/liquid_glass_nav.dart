import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 窄屏「镀铬件」是否走液态玻璃（真 shader 折射）。
///
/// 现在管辖两处：底部导航胶囊，以及窄屏页头的通用圆钮/胶囊（见
/// `mobile_top_bar_glass.dart`）。
///
/// 编译期默认值：`--dart-define=PA_LIQUID_GLASS_NAV=true` 打开。
/// 关掉时 `initialize()` / `wrap()` / `GlassContainer` 全部不参与，界面与引入
/// 依赖前逐像素一致——A/B 对比与回退都靠它。
const bool kLiquidGlassNavDefault = bool.fromEnvironment(
  'PA_LIQUID_GLASS_NAV',
  defaultValue: true,
);

/// 运行期开关。默认取编译期值；测试可以临时改动后 `tearDown` 复原。
///
/// 为什么不是纯编译期常量：widget 测试里要验证"开关打开时背板换成
/// `GlassContainer`、几何不变"，`const` 在测试进程里改不了。
bool liquidGlassNavEnabled = kLiquidGlassNavDefault;

/// 预热 shader。只在开关打开时执行：它做的是磁盘→内存 I/O，不影响首帧。
Future<void> initLiquidGlassNav() async {
  if (!kLiquidGlassNavDefault) {
    return;
  }
  await LiquidGlassWidgets.initialize();
}

/// 根级包裹：给玻璃组件接上亮度解析与无障碍桥接（Reduce Motion 等）。
///
/// 关掉时原样返回，不往树上多加一层。
Widget wrapLiquidGlassNav({required Widget child}) {
  if (!kLiquidGlassNavDefault) {
    return child;
  }
  return LiquidGlassWidgets.wrap(
    child: child,
    brightnessResolver: resolveLiquidGlassBrightness,
  );
}

/// 玻璃组件要的「当前亮度」。
///
/// 不能直接用设备亮度：本项目有「个性主题包」，包可能把 App 固定成浅色而设备
/// 是深色。`Theme.maybeBrightnessOf` 读的是 `MaterialApp` 依据 `ThemeMode` 与主题包
/// 解析后的亮度，正好是我们要的；拿不到时退回设备亮度。
Brightness? resolveLiquidGlassBrightness(BuildContext context) {
  return Theme.maybeBrightnessOf(context) ??
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
}

/// 补一层 `Material` 祖先。
///
/// 目标包刻意不依赖 Material：缺祖先时它内部的 `Text` 会画出黄色双下划线。
/// 只在开关打开时补，避免给现有页面叠一层多余的 Material。
Widget maybeGlassMaterialAncestor({required Widget child}) {
  if (!kLiquidGlassNavDefault) {
    return child;
  }
  return Material(type: MaterialType.transparency, child: child);
}
