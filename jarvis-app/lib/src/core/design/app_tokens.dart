/// 全站尺寸与字体族 token。
///
/// 这里是"数字"的唯一出口：任何界面代码想写字号、圆角、等宽字体族，
/// 都必须从这里取，不要再写裸值。理由很实际——改造前全站散着 13 档字号
/// （9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 14 / 16 / 18 / 20 / 22 / 24），
/// 相邻两档只差 0.5，靠注释区分"这处为什么用 12、那处为什么用 11.5"，
/// 加一个界面就得先猜一遍历史。
///
/// 现在只有五档 UI 字阶（[xs] [sm] [md] [base] [lg]），外加一条独立的内容标题
/// ramp（[h3] [h2] [h1]）与展示型两档（[display] [displayLg]）。
/// 内容标题不并进五档：Markdown 的 h1/h2 必须比正文明显大，压到 16 会让
/// 长文档失去层次；展示型是标题栏与标语，本来就不属于"界面控件文字"。
///
/// 纯 const，不依赖 `BuildContext`：需要上下文才能取的颜色在 [AppPalette]，
/// 两者分开之后，`const TextStyle(fontSize: AppFontSize.md)` 这种写法才成立。
library;

import 'package:flutter/painting.dart';

/// 字号：五档 UI 字阶 + 内容标题 + 展示型。
///
/// 命名用尺码（xs/sm/md/base/lg）而不是用途（caption/body/title）：
/// 同一个尺码在不同场景有不同字重，用途命名会逼着人再造一套别名。
abstract final class AppFontSize {
  /// 徽标、时间戳、文件大小、路径这类"扫一眼就够"的信息。
  static const double xs = 10.5;

  /// 元信息、说明段落、面板标签名、终端状态栏。
  static const double sm = 11.5;

  /// 等宽代码正文、面板栏头标题、消息状态标签。
  ///
  /// 列表行、菜单条目、胶囊按钮、详情页 Tab 已上移到 [base]：
  /// 控件文字与正文同号之后，层次靠字重与颜色分，不再靠 1.5px 的差。
  /// 这一档留给"内容里比正文小一号的字"——代码要能一屏多放几行。
  static const double md = 12.5;

  /// 正文、输入框、按钮文案、列表行主文字、菜单条目、胶囊按钮、详情页 Tab。
  static const double base = 14;

  /// 分组标题、卡片标题、列表项标题。
  static const double lg = 16;

  /// Markdown h3。
  static const double h3 = 16;

  /// Markdown h2。
  static const double h2 = 18;

  /// Markdown h1。
  static const double h1 = 20;

  /// 页面标题、`titleLarge`。
  static const double display = 22;

  /// 配对页标题、`headlineSmall`。
  static const double displayLg = 24;

  /// 新会话空态的品牌行（「探索未来」）。
  ///
  /// 比 [displayLg] 再大一档：那一行是空会话页唯一的视觉重心，页面没有别的内容
  /// 跟它抢层级。别处不要用——控件文字超过 24 就只剩"标题在喊"的观感了。
  static const double displayXl = 36;
}

/// 字重：只保留全站真正用到的四档。
abstract final class AppWeight {
  static const regular = FontWeight.w400;

  /// 桌面端的"强调"：按钮、选中行。再往上会显得像标签而不是内容。
  static const medium = FontWeight.w500;

  static const semiBold = FontWeight.w600;

  /// 只给标题与模式名：全大写或短词才撑得住。
  static const bold = FontWeight.w700;
}

/// 行高倍数。
abstract final class AppLineHeight {
  /// 单行控件：行高跟随字号，多出来的部分会把行撑高、把按钮挤歪。
  static const double tight = 1.2;

  /// 等宽正文：代码需要比普通段落紧一点，否则一屏放不下几行。
  static const double code = 1.45;

  /// 普通段落。
  static const double normal = 1.5;

  /// 回答正文：中文长段落需要更松的行距才好读。
  static const double relaxed = 1.6;

  /// 终端字符网格。
  ///
  /// 只给终端：行高直接决定一屏能放多少行，不能跟着 UI 的 1.2 走。
  static const double terminal = 1.35;
}

/// 字距。字号越大越需要拉开，但只允许这三档。
abstract final class AppLetterSpacing {
  /// 徽标、分组标题、菜单别名、状态栏这类小字。
  static const double tight = 0.3;

  /// 模式名、大标题。
  static const double wide = 0.6;

  /// 展示型大标题：全站唯一允许超过 0.6 的场合（配对页标题）。
  static const double display = 1.2;
}

/// 圆角。改造前每个组件各写一个数，这里只收口最常用的六档。
abstract final class AppRadius {
  /// 行内小块、徽标。
  static const double xs = 6;

  /// 行悬停底、代码块。
  static const double sm = 8;

  /// 面板、卡片、输入栏、消息气泡。
  static const double md = 12;

  /// 大卡片、弹层、表单与选择卡片、主按钮。
  static const double lg = 16;

  /// 大图标底座：60~80 见方的渐变方块。
  static const double xl = 24;

  /// 胶囊与圆角容器。
  static const double pill = 999;
}

/// 等宽字体族。
///
/// 改造前两套写法混用：`monospace`（11 处）与 `Menlo`（5 处）。
/// 前者在 macOS 上会落到系统默认的等宽字体，与设计稿对不上；后者在
/// Windows / Linux 上直接找不到字体，退回未知字形宽度。
/// 统一成"首选 Menlo，逐级 fallback"，三端至少命中一个。
abstract final class AppMono {
  static const String family = 'Menlo';

  static const List<String> fallback = <String>[
    'SF Mono',
    'Consolas',
    'DejaVu Sans Mono',
    'Noto Sans Mono CJK SC',
    'monospace',
  ];
}
