import 'package:flutter/material.dart';

/// 三栏栏底的不透明度。
///
/// 半透明而非实色：骨架（`HomeShell`）背后是整窗渐变（`appSurfaceGradient`），
/// 实色栏底会在窗口顶部——渐变最强的那一段——拉出一道硬边。左栏、右栏、
/// 栏缝拖动条与中栏共用这一份，少一处就会看到相邻两栏深浅不一样。
const double kPaneSurfaceAlpha = 0.6;

/// 栏底颜色：半透明 surface，让骨架的整窗渐变透上来。
///
/// 中栏的几个页面（会话 / 项目 / 任务）都用它当 `Scaffold.backgroundColor`，
/// 且只在宽屏内嵌形态用。窄屏的整页路由不传底色，交给 `AppPageScaffold`
/// 在路由内部铺一层不透明的整窗渐变（见 `core/ui/app_page_scaffold.dart`）：
/// 那层自己就是不透明的，转场时不会露出下层的列表。
Color paneSurfaceColor(ColorScheme scheme) =>
    scheme.surface.withValues(alpha: kPaneSurfaceAlpha);
