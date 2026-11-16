import 'package:flutter/material.dart';

import 'app_theme_spec.dart';

/// 内置浅色 / 深色主题的配色表。
///
/// 与用户安装的主题包**完全同规格**：键就是 `theme.json` 里 `colors` 那一套
/// （`seed` / `scheme` / `text` / `status` / `syntax` / `message` / `terminal` /
/// `accent` / `surface`），没写的格子继续从种子色派生。
///
/// 它是内置主题的**唯一配色入口**：`buildAppTheme` 先叠这张表、再叠用户选中的
/// 主题包（包里的同名格覆盖这里的值）。要调内置主题就改这两张表，不用碰
/// `AppColors` 常量，也不改装配逻辑。
///
/// 两条约定：
///
/// - `surface.top_tint` 决定整窗底色顶部那层淡色：**透明 = 纯色底（不铺渐变）**。
///   两套内置主题现在都是纯色；将来想恢复渐变，把这一格改成任意颜色即可——
///   不需要在代码里判断"是不是内置主题"，主题包也用同一格。
/// - `accent` 是"正常 / 进行中"的强调色（项目卡片左竖条与计数胶囊、底部导航选中、
///   通话页麦克风、录音页模式入口与「已转写」标签、SSH 连接表单）。内置取与主色
///   同源的蓝，并按明暗分开：浅色主题用深蓝、深色主题用亮蓝——这一档会被当文字
///   与图标色放在各自的页面底上，一个中间调蓝在两头都过不了对比度。
///
/// 这里只放"与派生值不同"的格；整张表清空也能跑（等于回到纯派生）。
const AppThemeColors builtinLightTheme = AppThemeColors(<String, Color>{
  // 纯色底：不铺顶部渐变。
  'surface.top_tint': Color(0x00000000),
  'accent.project_start': Color(0xFF2F5C8A),
  'accent.project_end': Color(0xFF4E86B6),
  'accent.ssh_start': Color(0xFF2A6C93),
  'accent.ssh_end': Color(0xFF4A93AE),
});

const AppThemeColors builtinDarkTheme = AppThemeColors(<String, Color>{
  // 纯色底：不铺顶部渐变。
  'surface.top_tint': Color(0x00000000),
  'accent.project_start': Color(0xFF93B8E4),
  'accent.project_end': Color(0xFFBBD2EC),
  'accent.ssh_start': Color(0xFF7FB6D6),
  'accent.ssh_end': Color(0xFF9FD2E0),
});

/// 取某一明暗的内置主题配色表。
AppThemeColors builtinThemeColors(Brightness brightness) =>
    brightness == Brightness.dark ? builtinDarkTheme : builtinLightTheme;
