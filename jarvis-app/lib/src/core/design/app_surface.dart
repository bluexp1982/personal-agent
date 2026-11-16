import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 渐变首段叠在页面底色上的色调强度。
///
/// 强度是版式常量，不进主题包：包只决定"偏哪个色"（`surface.top_tint`），
/// 换个强度等于换一版设计，不是换肤。
const double kSurfaceTopTintAlpha = 0.16;

/// 渐变收敛到底色的位置（占整屏高度的比例）。
const double kSurfaceTopTintStop = 0.34;

/// 整窗页面底色：配置给的那层淡色压在顶部，[kSurfaceTopTintStop] 处收敛为
/// `scheme.surface`，其余保持纯底色。
///
/// 色调来自 `palette.surface.topTint`。**缺省是全透明 = 不铺渐变（纯色底）**：
/// 两套内置主题都不铺（见 `app_builtin_themes.dart`），五个示例主题包显式给了色。
/// 三段同色时视觉上就是一块纯色，装饰层结构保持不变。
///
/// **唯一出处**：骨架（`HomeShell`）、整页面板、窄屏整页路由都从这里取。
/// 页面里不要再自己拼 `LinearGradient`：改一次色值要全站一致，
/// 各拼一份的结果就是某些页面永远比别的页面暖一点。
///
/// 首段用 [Color.alphaBlend] 预乘成不透明色，而不是直接把 16% 的色调交给
/// 渐变：整页路由把它当最外层的底色时，半透明首段会在转场期间透出下层列表
/// （见 `pane_surface.dart` 里那条“半透明会在转场时露出下层”的教训）。
/// 预乘后叠加效果完全相同，但这一层自己就是不透明的；色调全透明时首段就等于
/// `scheme.surface`，整条渐变退化成纯色。
LinearGradient appSurfaceGradient(AppPalette palette, ColorScheme scheme) {
  final top = appSurfaceTopColor(palette, scheme);

  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[top, scheme.surface, scheme.surface],
    stops: const <double>[0, kSurfaceTopTintStop, 1],
  );
}

/// 渐变首段那个"顶部色"：主题染色按 [kSurfaceTopTintAlpha] 预乘到整页底色上。
///
/// 单独抽出来是给顶部虚化带用的：页头背后那条带子必须用**和它背后同一个色**，
/// 否则深色主题下（`scheme.surface` 近黑）会在页头下沿切出一条比周围更深的横带
/// ——实测过，0.8 的近黑压在染色底上会出现 39→15 的硬跳变。
Color appSurfaceTopColor(AppPalette palette, ColorScheme scheme) {
  final tint = palette.surface.topTint;
  // 色调被显式关掉（全透明）时不叠任何颜色：三段同色 = 纯色底。
  // 注意不能直接 `tint.withValues(alpha: 16%)`——那会把"透明"变成"16% 的黑"。
  if (tint.a == 0) {
    return scheme.surface;
  }
  return Color.alphaBlend(
    tint.withValues(alpha: kSurfaceTopTintAlpha),
    scheme.surface,
  );
}

/// 整窗渐变在 [fraction]（0..1，自顶向下占窗高的比例）处的颜色。
///
/// 和 [appSurfaceGradient] 的 `stops [0, kSurfaceTopTintStop, 1]` 是同一条曲线：
/// 取出来的颜色就是"画在那一行的颜色"，两边不会各自漂移。
///
/// 顶部虚化带的填充要用**它自己上沿那一刻**的渐变色，而不是窗口最顶色：
/// 带子上沿在 SafeArea 之下（状态栏底边），那里的渐变已经暗了一档，
/// 拿最顶色去盖会抬亮 2~3 个亮度，留下一条细横线（实测 39→43 的台阶）。
Color appSurfaceColorAt(
  AppPalette palette,
  ColorScheme scheme,
  double fraction,
) {
  final top = appSurfaceTopColor(palette, scheme);
  // 不染色的主题（内置浅色/深色）整条渐变就是纯色：直接返回，别让
  // `Color.lerp` 造出一个"数值相同、色彩空间不同"的新对象。
  if (palette.surface.topTint.a == 0 ||
      fraction <= 0 ||
      kSurfaceTopTintStop <= 0) {
    return top;
  }
  final t = (fraction / kSurfaceTopTintStop).clamp(0.0, 1.0);
  return Color.lerp(top, scheme.surface, t)!;
}
