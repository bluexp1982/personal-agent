import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_tokens.dart';

/// 语义化文字样式。
///
/// 改造前每个组件都自己拼 `Theme.of(context).textTheme.xxx?.copyWith(...)`：
/// 字号、字重、颜色、行高四项各写各的，于是"元信息"在时间戳那里是 12，
/// 在状态行那里是 12.5，在代码块语言标签那里是 11.5——三处都叫元信息。
///
/// 这里把反复出现的组合收成命名 getter。命名只用界面里的真实角色
/// （正文 / 行 / 元信息 / 徽标 / 分组标题），不做"字号别名"。
///
/// 为什么挂在 `textTheme` 上再 copyWith：裸 `TextStyle` 不带字体族与
/// 平台微调，某些容器（`MenuItemButton`、`SubmenuButton` 内层的 TextButton）
/// 还会把自己的 `labelLarge`（w500）通过 DefaultTextStyle 塞进来，
/// 于是同一行文字在两处一粗一细。继承再覆盖可以避开这个坑。
@immutable
class AppText {
  const AppText._(this._theme, this._palette);

  final TextTheme _theme;
  final AppPalette _palette;

  static AppText of(BuildContext context) =>
      AppText._(Theme.of(context).textTheme, AppPalette.of(context));

  // ---------------------------------------------------------------------------
  // 正文
  // ---------------------------------------------------------------------------

  /// 回答正文、段落：14 / 1.6。
  TextStyle get body => (_theme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.base,
    height: AppLineHeight.relaxed,
    color: _palette.text.primary,
  );

  /// 紧凑正文：气泡、说明段这类空间有限的地方：14 / 1.5。
  TextStyle get bodyTight => (_theme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.base,
    height: AppLineHeight.normal,
    color: _palette.text.primary,
  );

  // ---------------------------------------------------------------------------
  // 行
  // ---------------------------------------------------------------------------

  /// 列表行、菜单条目的主文字：14 / 1.2。
  TextStyle get row => (_theme.bodyMedium ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.base,
    height: AppLineHeight.tight,
    color: _palette.text.primary,
  );

  /// 行内次要文字（未选中的行、胶囊按钮）：14。
  TextStyle get rowSecondary =>
      (_theme.bodyMedium ?? const TextStyle()).copyWith(
        fontSize: AppFontSize.base,
        height: AppLineHeight.tight,
        color: _palette.text.secondary,
      );

  // ---------------------------------------------------------------------------
  // 小字
  // ---------------------------------------------------------------------------

  /// 元信息：时间戳、用量、语言标签、状态栏：11.5。
  TextStyle get meta => (_theme.labelSmall ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.sm,
    height: AppLineHeight.tight,
    color: _palette.text.tertiary,
  );

  /// 说明与提示：11.5，与 [meta] 同色不同行高。
  TextStyle get hint => (_theme.labelSmall ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.sm,
    height: AppLineHeight.normal,
    color: _palette.text.tertiary,
  );

  /// 徽标（EXP / Git / 即将支持）：10.5 / w600。
  TextStyle get badge => (_theme.labelSmall ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.xs,
    height: AppLineHeight.tight,
    fontWeight: AppWeight.semiBold,
    letterSpacing: AppLetterSpacing.wide,
    color: _palette.text.tertiary,
  );

  // ---------------------------------------------------------------------------
  // 标题
  // ---------------------------------------------------------------------------

  /// 分组标题（设置页「连接 / 外观」这类）：16 / w500。
  TextStyle get section => (_theme.titleMedium ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.lg,
    color: _palette.text.primary,
  );

  /// 卡片 / 列表项标题：16 / w600。
  TextStyle get cardTitle => (_theme.titleMedium ?? const TextStyle()).copyWith(
    fontSize: AppFontSize.lg,
    fontWeight: AppWeight.semiBold,
    color: _palette.text.primary,
  );

  /// 弹窗标题：22 / w700 / 1.2。
  ///
  /// 字号取 [AppFontSize.display]（`titleLarge` 那一档），字重取 [AppWeight.bold]：
  /// 这是「设置 / 模型配置 / 新建项目」原来各自用 `titleLarge + bold` 拼出来的那份，
  /// 收进来之后全站弹窗只此一处，别再散落 titleLarge / titleMedium / cardTitle 三套。
  TextStyle get dialogTitle =>
      (_theme.titleLarge ?? const TextStyle()).copyWith(
        fontSize: AppFontSize.display,
        height: AppLineHeight.tight,
        fontWeight: AppWeight.bold,
        color: _palette.text.primary,
      );

  // ---------------------------------------------------------------------------
  // 等宽
  // ---------------------------------------------------------------------------

  /// 等宽文字：默认 12.5，可选覆盖字号/行高/颜色。
  ///
  /// 字体族与 fallback 统一从 [AppMono] 取：改造前 `'monospace'` 与 `'Menlo'`
  /// 混用，后者在 Windows / Linux 上根本不存在，字形宽度会退回默认比例字体，
  /// 缩进与列对齐会歪。
  TextStyle mono({double size = AppFontSize.md, double? height, Color? color}) {
    return (_theme.bodyMedium ?? const TextStyle()).copyWith(
      fontFamily: AppMono.family,
      fontFamilyFallback: AppMono.fallback,
      fontSize: size,
      height: height ?? AppLineHeight.code,
      color: color ?? _palette.text.primary,
    );
  }
}
