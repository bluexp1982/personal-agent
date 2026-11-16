import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// 终端配色：跟随应用明暗，而不是永远黑底。
///
/// 之前终端是写死的深色（`#0B0F14`），浅色界面里像嵌了一块黑砖：
/// 状态栏、复制粘贴浮条、断线遮罩也一起是深色，跟面板其余部分明显两层皮。
/// 现在所有与终端相关的底色都从这里取，切主题时只换这一份常量，
/// 不再满文件找写死的颜色。
///
/// 为什么不给终端单独一个开关：用户已经在设置里选过"跟随系统 / 浅色 / 深色"，
/// 再给终端一份独立偏好，就会出现"界面浅色、终端黑色"的组合，
/// 而这个组合几乎不会有人是主动想要的。
///
/// 值类型：明暗两份实例由 [AppPalette] 装配，界面一律走
/// `AppPalette.of(context).terminal`。这里的 `light` / `dark` 是为了让
/// [AppPalette] 保持 const 才公开的常量，不要直接引用。
@immutable
class TerminalPalette {
  const TerminalPalette({
    required this.theme,
    required this.background,
    required this.chrome,
    required this.chromeBorder,
    required this.chromeForeground,
    required this.overlay,
    required this.keyboardAppearance,
  });

  /// xterm 用的完整调色板（ANSI 十六色 + 光标 + 选区 + 搜索高亮）。
  final TerminalTheme theme;

  /// 终端画布底色。与 [theme] 的 background 一致，单独给 `DecoratedBox` 用，
  /// 避免在 widget 里再取一次 `theme.background`。
  final Color background;

  /// 状态栏、快捷键条这类"终端附件"的底色。
  final Color chrome;

  /// [chrome] 上的分隔线。
  final Color chromeBorder;

  /// [chrome] 上的次要文字与图标。
  final Color chromeForeground;

  /// 断线遮罩：盖住输出但仍要能看见底下最后几行。
  final Color overlay;

  /// 软键盘的外观（iOS 上深色键盘配深色终端，浅色反之）。
  final Brightness keyboardAppearance;

  /// 深色：沿用改造前那套颜色，老用户的观感不变。
  static const TerminalPalette dark = TerminalPalette(
    theme: TerminalTheme(
      cursor: Color(0xFF38BDF8),
      selection: Color(0x552F9E68),
      foreground: Color(0xFFE6EDF3),
      background: Color(0xFF0B0F14),
      black: Color(0xFF111820),
      red: Color(0xFFEF4444),
      green: Color(0xFF22C55E),
      yellow: Color(0xFFF59E0B),
      blue: Color(0xFF38BDF8),
      magenta: Color(0xFFC084FC),
      cyan: Color(0xFF17A398),
      white: Color(0xFFD6DEE7),
      brightBlack: Color(0xFF6B7684),
      brightRed: Color(0xFFF87171),
      brightGreen: Color(0xFF4ADE80),
      brightYellow: Color(0xFFFBBF24),
      brightBlue: Color(0xFF7DD3FC),
      brightMagenta: Color(0xFFD8B4FE),
      brightCyan: Color(0xFF5EEAD4),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0x66F59E0B),
      searchHitBackgroundCurrent: Color(0xAA2F9E68),
      searchHitForeground: Color(0xFF0B0F14),
    ),
    background: Color(0xFF0B0F14),
    chrome: Color(0xFF111820),
    chromeBorder: Color(0x14FFFFFF),
    chromeForeground: Color(0xFFA9B4C0),
    overlay: Color(0xB80B0F14),
    keyboardAppearance: Brightness.dark,
  );

  /// 浅色：近白底、深字，ANSI 各色整体压深。
  ///
  /// 关键不是"把深色配色反相"，而是保证白底上的对比度：
  /// 深色终端里的 `white` / `brightWhite` 在浅色底上会直接看不见，
  /// 这里改成中灰；黄、青这类高明度色也换成更暗的色阶。
  static const TerminalPalette light = TerminalPalette(
    theme: TerminalTheme(
      cursor: Color(0xFF0969DA),
      selection: Color(0x332F9E68),
      foreground: Color(0xFF1B1F27),
      background: Color(0xFFFCFCFD),
      black: Color(0xFF24292F),
      red: Color(0xFFCF222E),
      green: Color(0xFF116329),
      yellow: Color(0xFF7D4E00),
      blue: Color(0xFF0969DA),
      magenta: Color(0xFF8250DF),
      cyan: Color(0xFF1B7C83),
      white: Color(0xFF6E7781),
      brightBlack: Color(0xFF57606A),
      brightRed: Color(0xFFA40E26),
      brightGreen: Color(0xFF1A7F37),
      brightYellow: Color(0xFF9A6700),
      brightBlue: Color(0xFF218BFF),
      brightMagenta: Color(0xFFA475F9),
      brightCyan: Color(0xFF3192AA),
      brightWhite: Color(0xFF8C959F),
      searchHitBackground: Color(0x66F59E0B),
      searchHitBackgroundCurrent: Color(0xAA116329),
      searchHitForeground: Color(0xFF1B1F27),
    ),
    background: Color(0xFFFCFCFD),
    chrome: Color(0xFFF3F4F8),
    chromeBorder: Color(0x14101828),
    chromeForeground: Color(0xFF57606A),
    overlay: Color(0xB8FCFCFD),
    keyboardAppearance: Brightness.light,
  );
}
