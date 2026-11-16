import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'app_builtin_themes.dart';
import 'app_theme_spec.dart';
import 'message_palette.dart';
import 'terminal_palette.dart';

/// 全站颜色的唯一出口。
///
/// 改造前颜色分三处住：M3 的 `ColorScheme`（种子色派生）、4 个调色板文件
/// （消息 / 终端 / 模式 / 图标）与 5 个散点的状态色。同一个"绿"在四个文件里
/// 各写一遍 `Color(0xFF22C55E)`，改一处就漏三处；文字灰阶则是把
/// `onSurfaceVariant` 叠上 0.45~0.85 七种 alpha，叠在深一点的容器底上
/// 直接掉到 2.6:1，读不清。
///
/// 现在分两层：
/// - 静态常量 [AppColors]：与明暗无关的原始色值（状态色、模式三色、图标色），
///   给 `const` 场景（例如 `ModeStyle`）用。
/// - [AppPalette]：把"跟随主题"的那部分装配成 ThemeExtension，界面通过
///   `AppPalette.of(context)` 取。文字四档灰阶、状态五色、消息与终端两套
///   调色板都在这里。
///
/// 为什么文字灰阶用实色而不是 alpha：`onSurfaceVariant@0.55` 在 `surface`
/// 上是 3.3:1，在 `surfaceContainerHighest` 上就只剩 2.4:1——同一个 token
/// 在不同容器上表现不同，是"弱化文字读不清"的根因。改成实色后，对比度
/// 与它落在哪一层无关，[AppTextColors.tertiary] 在三层底上都 ≥ 4.5:1。
abstract final class AppColors {
  /// 主题种子色。改它等于换肤，其余 M3 色阶全部跟着走。
  static const Color seed = Color(0xFF3B6EA5);

  /// 渐变底 / 主色底上的文字与图标。
  ///
  /// 与明暗无关，恒为白，所以能用在 `const` 的图标与文字样式里；
  /// 有 `BuildContext` 时优先用 `palette.text.onAccent`。
  static const Color onAccent = Color(0xFFFFFFFF);

  // ---------------------------------------------------------------------------
  // 状态色
  // ---------------------------------------------------------------------------

  /// 浅色主题压到 800 档，深色保持原值。
  ///
  /// 为什么不沿用改造前的 `#22C55E` / `#F59E0B`：那两档对 `#F8F9FF` 的对比度
  /// 只有 2.2:1 / 2.0:1，而它们承载的是 11.5px 的胶囊文字。并且状态胶囊
  /// 自带 12% 同色底，底色一变浅，对比度还会再掉一点——按 800 档取，
  /// 文字在"页面底"和"自色 12% 底"上都能过 4.5:1。
  static const Color statusSuccessLight = Color(0xFF166534);
  static const Color statusSuccessDark = Color(0xFF22C55E);
  static const Color statusWarningLight = Color(0xFF92400E);
  static const Color statusWarningDark = Color(0xFFF59E0B);
  static const Color statusDangerLight = Color(0xFFB42318);

  /// 深色危险色比改造前的 `#EF4444` 再亮一档。
  ///
  /// 红色在深底上的可用亮度窗口很窄：`#EF4444` 对 `#111418` 有 5.0:1，
  /// 但状态胶囊自带 12% 同色底，底色一亮，它自己反而掉到 4.39:1。
  /// 提到 `#F87171`（与终端 brightRed 同源）后，两种底都在 5.7:1 以上。
  static const Color statusDangerDark = Color(0xFFF87171);
  static const Color statusInfoLight = Color(0xFF075985);
  static const Color statusInfoDark = Color(0xFF38BDF8);
  static const Color statusNeutralLight = Color(0xFF4B5563);
  static const Color statusNeutralDark = Color(0xFF8C97A6);

  // ---------------------------------------------------------------------------
  // 文字
  // ---------------------------------------------------------------------------

  /// 弱化文字（时间戳、说明、徽标）的实色。
  ///
  /// 浅色定的是视觉取向：`#ADB2B9` 对三种浅底只有 1.65–2.13:1，**不满足**
  /// 文档第十二节的 4.5:1 红线，是需求方指定的例外（占位提示、时间戳这类
  /// 不承载关键信息的文字）。别再往更淡调，否则连"看得到"都保不住。
  /// 深色仍是达标的 `#98A0AC`（5.77:1 以上），两侧不同步是有意的。
  static const Color textTertiaryLight = Color(0xFFADB2B9);
  static const Color textTertiaryDark = Color(0xFF98A0AC);

  /// 控件入口（输入栏胶囊触发器）的文字灰：比 `secondary` 淡、比 `tertiary` 深。
  ///
  /// 取自 Claude / DeepSeek 客户端的控件行——常驻时"看得见但不争抢"。
  /// 它不是第五档通用灰阶，只给 [AppTextColors.control] 用，
  /// 别再扩散到正文、元信息或占位提示。
  static const Color textControlLight = Color(0xFF7B7F83);
  static const Color textControlDark = Color(0xFFA8AEB6);

  // ---------------------------------------------------------------------------
  // 强调色
  // ---------------------------------------------------------------------------

  /// 项目走主色同源的蓝，SSH 走同色系偏青的蓝（终端感）。
  ///
  /// 界面已不再区分 CODE / WORK，所以项目只保留这一套色；两组渐变都不分明暗。
  /// 这里只是**兜底值**（浅色那一组）：内置浅色 / 深色的实际取色写在
  /// `app_builtin_themes.dart`——那一档会被当文字与图标色放在各自页面底上，
  /// 深色主题需要更亮的一组，见 `builtinDarkTheme`。
  static const Color projectStart = Color(0xFF2F5C8A);
  static const Color projectEnd = Color(0xFF4E86B6);
  static const Color sshStart = Color(0xFF2A6C93);
  static const Color sshEnd = Color(0xFF4A93AE);

  // ---------------------------------------------------------------------------
  // 霓虹流光
  // ---------------------------------------------------------------------------
  //
  // 只服务输入面板「等待首个 token」时的那圈描边（见 `app_flow_border.dart`），
  // 不属于语义调色板：它不表达状态、不跟随主题，也不该被用到按钮或文字上。
  // 色相按"青 → 蓝 → 紫 → 粉 → 红 → 橙 → 绿"排列，与参考图的整圈彩虹一致。

  static const Color flowCyan = Color(0xFF22D3EE);
  static const Color flowBlue = Color(0xFF3B82F6);
  static const Color flowViolet = Color(0xFFA855F7);
  static const Color flowPink = Color(0xFFEC4899);
  static const Color flowRose = Color(0xFFF43F5E);
  static const Color flowOrange = Color(0xFFFB923C);
  static const Color flowGreen = Color(0xFF22C55E);

  // ---------------------------------------------------------------------------
  // 语法高亮
  // ---------------------------------------------------------------------------
  //
  // 取值口径：在"代码块底"（浅 #F3F4F6 / 深 #24272D）与三档容器底上
  // 都 ≥ 4.5:1，由 `design_tokens_test` 锁死。浅色整体压到 700/800 档，
  // 深色整体提到 300 档——语法色承载的是"能读"而不只是"能分辨"，
  // 沿用编辑器主题的亮紫/亮绿在浅底上只有 2~3:1。
  //
  // 关键字与属性的紫刻意分开（#A626A4 vs #A21CAF）：`const` 与 `name:`
  // 常在同一行出现，同色会让整行糊成一片。

  static const Color syntaxKeywordLight = Color(0xFFA626A4);
  static const Color syntaxKeywordDark = Color(0xFFC792EA);
  static const Color syntaxStringLight = Color(0xFF116329);
  static const Color syntaxStringDark = Color(0xFFA5D6A7);
  static const Color syntaxNumberLight = Color(0xFF9A3412);
  static const Color syntaxNumberDark = Color(0xFFF78C6C);
  static const Color syntaxCommentLight = Color(0xFF555D68);
  static const Color syntaxCommentDark = Color(0xFFA3ABB8);
  static const Color syntaxFunctionLight = Color(0xFF1D4ED8);
  static const Color syntaxFunctionDark = Color(0xFF82AAFF);
  static const Color syntaxTypeLight = Color(0xFF0B677D);
  static const Color syntaxTypeDark = Color(0xFFFFCB6B);
  static const Color syntaxVariableLight = Color(0xFF0B6157);
  static const Color syntaxVariableDark = Color(0xFF89DDFF);
  static const Color syntaxPropertyLight = Color(0xFFA21CAF);
  static const Color syntaxPropertyDark = Color(0xFFC3E88D);
  static const Color syntaxOperatorLight = Color(0xFF4B5563);
  static const Color syntaxOperatorDark = Color(0xFF89DDFF);
  static const Color syntaxMetaLight = Color(0xFFBE123C);
  static const Color syntaxMetaDark = Color(0xFFF58A90);
  static const Color syntaxInvalidLight = Color(0xFFB42318);
  static const Color syntaxInvalidDark = Color(0xFFFF8A8A);
}

/// 文字四档灰阶。
///
/// 只有四档是刻意的：再细分一定会有人开始调 0.02 的 alpha，
/// 而人眼分不出相邻两档，只会让"这处为什么更淡"变成不可回答的问题。
@immutable
class AppTextColors {
  const AppTextColors({
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.control,
    required this.disabled,
    required this.onAccent,
  });

  /// 正文、标题、行主文字。
  final Color primary;

  /// 副标题、未选中的标签页、辅助图标。
  final Color secondary;

  /// 时间戳、说明、徽标、占位提示——一切"读得到但不抢注意力"的文字。
  final Color tertiary;

  /// 控件入口（胶囊触发器）的文字：常驻、悬停、展开都用这一档。
  ///
  /// 单独一格是因为 [secondary] 对它太重、[tertiary] 又太轻：这类入口正在
  /// 告诉用户"当前设成了什么"，不该和输入内容抢注意力，但也不能淡到看不清。
  final Color control;

  /// 禁用态：不再承载信息，只表明"这里的控件还在"。
  final Color disabled;

  /// 渐变底 / 主色底上的文字。始终是白色，不随主题变。
  final Color onAccent;
}

/// 状态五色。
///
/// 胶囊的 12% 底与 35% 描边都由同一个颜色派生：改一处，点和底一起变，
/// 不会出现"文字已经压深、底还是按旧色算"的半截更新。
@immutable
class AppStatusColors {
  const AppStatusColors({
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.neutral,
  });

  static const AppStatusColors light = AppStatusColors(
    success: AppColors.statusSuccessLight,
    warning: AppColors.statusWarningLight,
    danger: AppColors.statusDangerLight,
    info: AppColors.statusInfoLight,
    neutral: AppColors.statusNeutralLight,
  );

  static const AppStatusColors dark = AppStatusColors(
    success: AppColors.statusSuccessDark,
    warning: AppColors.statusWarningDark,
    danger: AppColors.statusDangerDark,
    info: AppColors.statusInfoDark,
    neutral: AppColors.statusNeutralDark,
  );

  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color neutral;

  /// 状态胶囊的底色。
  Color surfaceOf(Color color) => color.withValues(alpha: 0.12);

  /// 状态胶囊的描边。
  Color borderOf(Color color) => color.withValues(alpha: 0.35);
}

/// 语法高亮的文字色。
///
/// 为什么只有十一格：`re_highlight` 的 scope 有上百个（`title.function_`、
/// `string.regexp`、`meta.string.multiline`…），逐个配色既配不完也没人分得清。
/// 这里按 highlight.js 的 scope 首段收敛成十一类，其余用正文色。
///
/// 取值与对比度约束见 [AppColors] 的"语法高亮"一节。
@immutable
class AppSyntaxColors {
  const AppSyntaxColors({
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.function,
    required this.type,
    required this.variable,
    required this.property,
    required this.operator,
    required this.meta,
    required this.invalid,
  });

  static const AppSyntaxColors light = AppSyntaxColors(
    keyword: AppColors.syntaxKeywordLight,
    string: AppColors.syntaxStringLight,
    number: AppColors.syntaxNumberLight,
    comment: AppColors.syntaxCommentLight,
    function: AppColors.syntaxFunctionLight,
    type: AppColors.syntaxTypeLight,
    variable: AppColors.syntaxVariableLight,
    property: AppColors.syntaxPropertyLight,
    operator: AppColors.syntaxOperatorLight,
    meta: AppColors.syntaxMetaLight,
    invalid: AppColors.syntaxInvalidLight,
  );

  static const AppSyntaxColors dark = AppSyntaxColors(
    keyword: AppColors.syntaxKeywordDark,
    string: AppColors.syntaxStringDark,
    number: AppColors.syntaxNumberDark,
    comment: AppColors.syntaxCommentDark,
    function: AppColors.syntaxFunctionDark,
    type: AppColors.syntaxTypeDark,
    variable: AppColors.syntaxVariableDark,
    property: AppColors.syntaxPropertyDark,
    operator: AppColors.syntaxOperatorDark,
    meta: AppColors.syntaxMetaDark,
    invalid: AppColors.syntaxInvalidDark,
  );

  /// `if` / `const` / `return` / 布尔字面量。
  final Color keyword;

  /// 字符串、正则、字符字面量。
  final Color string;

  /// 数字与其它字面量。
  final Color number;

  /// 注释（含文档注释）。不斜体：等宽中文斜体在部分字体上是拼接合成的。
  final Color comment;

  /// 函数名与调用目标。
  final Color function;

  /// 类型、类名、枚举名。
  final Color type;

  /// 变量、参数、`$this` / `self` 这类语言内置变量。
  final Color variable;

  /// 对象的键、属性、HTML/XML 属性名。
  final Color property;

  /// 运算符与标点。
  final Color operator;

  /// 预处理指令、注解、装饰器、diff 的增删标记。
  final Color meta;

  /// 编辑器标为非法/删除的 token。极少出现，但出现时应当是红的。
  final Color invalid;
}

/// 强调色：项目蓝 + 终端青蓝。
///
/// 值类型而不是"常量集合"：主题包可以覆盖这四格（`accent.project_start` 等），
/// 一旦留成读 [AppColors] 的 const getter，绿/紫色主题就会顶着一套不相干的
/// 项目卡片、计数胶囊与通话页麦克风。渐变与低饱和 `tint` 由这四个端点派生，
/// 包里不重复声明。
///
/// 内置的两套按明暗分组（写在 `app_builtin_themes.dart`）：浅色用深蓝、深色用
/// 亮蓝。这里的 [defaults] 只是"主题里没注册 `AppPalette` 时"的兜底，取浅色那组。
@immutable
class AppAccentColors {
  const AppAccentColors({
    required this.projectStart,
    required this.projectEnd,
    required this.sshStart,
    required this.sshEnd,
  });

  /// 兜底值（浅色那组）：内置浅 / 深的实际取色见 `app_builtin_themes.dart`。
  static const AppAccentColors defaults = AppAccentColors(
    projectStart: AppColors.projectStart,
    projectEnd: AppColors.projectEnd,
    sshStart: AppColors.sshStart,
    sshEnd: AppColors.sshEnd,
  );

  final Color projectStart;
  final Color projectEnd;
  final Color sshStart;
  final Color sshEnd;

  /// 项目身份渐变：列表卡片、主按钮、通话页麦克风。
  LinearGradient get projectGradient => LinearGradient(
    colors: <Color>[projectStart, projectEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// 终端（SSH）身份渐变。
  LinearGradient get sshGradient => LinearGradient(
    colors: <Color>[sshStart, sshEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// 卡片、徽标用的低饱和主色：直接从渐变里取中间色，保证与渐变同源。
  Color get projectTint => Color.lerp(projectStart, projectEnd, 0.35)!;

  Color get sshTint => Color.lerp(sshStart, sshEnd, 0.35)!;
}

/// 页面氛围色：整窗底色顶部那层淡色。
///
/// 只有一格：强度（16%）与收敛位置（34%）是版式常量，见 `app_surface.dart`；
/// 配置只决定"偏哪个色"。**缺省是全透明 = 不铺渐变（纯色底）**，想要渐变就显式
/// 给一个颜色（内置两套都不铺，见 `app_builtin_themes.dart`；四个示例主题包各自给了色）。
@immutable
class AppSurfaceColors {
  const AppSurfaceColors({required this.topTint});

  /// 默认不染色：`alphaBlend` 之后就是页面底色本身。
  static const AppSurfaceColors defaults = AppSurfaceColors(
    topTint: Color(0x00000000),
  );

  /// 渐变首段叠在 `scheme.surface` 上的色调；全透明表示不铺。
  final Color topTint;
}

/// 主题扩展：把上面几组颜色装配成可随主题切换的单一入口。
///
/// 用 ThemeExtension 而不是全局单例，是因为它跟 `Theme` 同生命周期：
/// 浅/深切换时 `of(context)` 拿到的必然是当前那一套，不存在"某个页面
/// 还拿着旧主题的颜色"这种只在换肤瞬间出现的脏状态。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.text,
    required this.status,
    required this.message,
    required this.terminal,
    required this.accent,
    required this.surface,
    required this.syntax,
  });

  /// 由已构造好的 `ColorScheme` 派生。
  ///
  /// 文字前两档直接取 scheme 的 `onSurface` / `onSurfaceVariant`：
  /// 它们已经满足对比度要求，没必要再造一组。后两档取实色。
  factory AppPalette.fromScheme(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return AppPalette(
      text: AppTextColors(
        primary: scheme.onSurface,
        secondary: scheme.onSurfaceVariant,
        tertiary: dark
            ? AppColors.textTertiaryDark
            : AppColors.textTertiaryLight,
        control: dark ? AppColors.textControlDark : AppColors.textControlLight,
        disabled: scheme.onSurface.withValues(alpha: 0.38),
        onAccent: AppColors.onAccent,
      ),
      status: dark ? AppStatusColors.dark : AppStatusColors.light,
      message: dark ? MessagePalette.dark : MessagePalette.light,
      terminal: dark ? TerminalPalette.dark : TerminalPalette.light,
      accent: AppAccentColors.defaults,
      surface: AppSurfaceColors.defaults,
      syntax: dark ? AppSyntaxColors.dark : AppSyntaxColors.light,
    );
  }

  /// 给测试与不依赖 context 的场景用：按明暗直接构造。
  ///
  /// 内部走 `ColorScheme.fromSeed` + 内置 spec，与生产主题同源，
  /// 不会出现"测试里一套色、界面上另一套"。
  static AppPalette forBrightness(Brightness brightness) =>
      AppPalette.fromScheme(
        ColorScheme.fromSeed(seedColor: AppColors.seed, brightness: brightness),
      ).overrideWith(builtinThemeColors(brightness));

  /// 用主题包的稀疏覆盖替换同名格子，未覆盖的保持内置派生值。
  ///
  /// 为什么不在 `fromScheme` 里加参数：那个签名被守护测试与大量 widget 测试
  /// 引用，改它会牵动几十处挂载代码；而"先派生、再覆盖"的语义也更清楚——
  /// 主题包永远只是"在内置主题上打补丁"，不可能造出一份缺格子的调色板。
  AppPalette overrideWith(AppThemeColors overrides) {
    if (overrides.isEmpty) {
      return this;
    }

    Color pick(String key, Color fallback) => overrides[key] ?? fallback;

    // 强调色四格一起替换（渐变与 tint 由端点派生）。
    final accentColors = AppAccentColors(
      projectStart: pick('accent.project_start', accent.projectStart),
      projectEnd: pick('accent.project_end', accent.projectEnd),
      sshStart: pick('accent.ssh_start', accent.sshStart),
      sshEnd: pick('accent.ssh_end', accent.sshEnd),
    );

    return AppPalette(
      text: AppTextColors(
        primary: pick('text.primary', text.primary),
        secondary: pick('text.secondary', text.secondary),
        tertiary: pick('text.tertiary', text.tertiary),
        control: pick('text.control', text.control),
        disabled: pick('text.disabled', text.disabled),
        // 强调底的文字恒为白：项目/终端渐变不随主题变，改了只会掉对比度。
        onAccent: text.onAccent,
      ),
      status: AppStatusColors(
        success: pick('status.success', status.success),
        warning: pick('status.warning', status.warning),
        danger: pick('status.danger', status.danger),
        info: pick('status.info', status.info),
        neutral: pick('status.neutral', status.neutral),
      ),
      message: MessagePalette(
        userBubble: pick('message.user_bubble', message.userBubble),
        codeBackground: pick('message.code_background', message.codeBackground),
        userText: pick('message.user_text', message.userText),
        meta: pick('message.meta', message.meta),
        divider: pick('message.divider', message.divider),
      ),
      terminal: _terminalWith(overrides, terminal),
      accent: accentColors,
      // 分层回退：没写 `surface.top_tint` 就沿用上一层（内置 spec 的透明，或
      // 更内层派生出的值），不会因为改了 accent 就"顺带"多出一层渐变色。
      surface: AppSurfaceColors(
        topTint: pick('surface.top_tint', surface.topTint),
      ),
      syntax: AppSyntaxColors(
        keyword: pick('syntax.keyword', syntax.keyword),
        string: pick('syntax.string', syntax.string),
        number: pick('syntax.number', syntax.number),
        comment: pick('syntax.comment', syntax.comment),
        function: pick('syntax.function', syntax.function),
        type: pick('syntax.type', syntax.type),
        variable: pick('syntax.variable', syntax.variable),
        property: pick('syntax.property', syntax.property),
        operator: pick('syntax.operator', syntax.operator),
        meta: pick('syntax.meta', syntax.meta),
        invalid: pick('syntax.invalid', syntax.invalid),
      ),
    );
  }

  /// 终端调色板要逐格拼一个新的 [TerminalTheme]：xterm 的 `TerminalTheme`
  /// 没有 `copyWith`，而这些格子正是主题包最容易改的一组。
  static TerminalPalette _terminalWith(
    AppThemeColors overrides,
    TerminalPalette base,
  ) {
    final theme = base.theme;
    Color pick(String key, Color fallback) => overrides[key] ?? fallback;

    return TerminalPalette(
      theme: TerminalTheme(
        cursor: pick('terminal.cursor', theme.cursor),
        selection: pick('terminal.selection', theme.selection),
        foreground: pick('terminal.foreground', theme.foreground),
        background: pick('terminal.background', theme.background),
        black: pick('terminal.black', theme.black),
        red: pick('terminal.red', theme.red),
        green: pick('terminal.green', theme.green),
        yellow: pick('terminal.yellow', theme.yellow),
        blue: pick('terminal.blue', theme.blue),
        magenta: pick('terminal.magenta', theme.magenta),
        cyan: pick('terminal.cyan', theme.cyan),
        white: pick('terminal.white', theme.white),
        brightBlack: pick('terminal.bright_black', theme.brightBlack),
        brightRed: pick('terminal.bright_red', theme.brightRed),
        brightGreen: pick('terminal.bright_green', theme.brightGreen),
        brightYellow: pick('terminal.bright_yellow', theme.brightYellow),
        brightBlue: pick('terminal.bright_blue', theme.brightBlue),
        brightMagenta: pick('terminal.bright_magenta', theme.brightMagenta),
        brightCyan: pick('terminal.bright_cyan', theme.brightCyan),
        brightWhite: pick('terminal.bright_white', theme.brightWhite),
        // 搜索高亮是"选中态"，由 xterm 的默认值承担；主题包不开放这两格。
        searchHitBackground: theme.searchHitBackground,
        searchHitBackgroundCurrent: theme.searchHitBackgroundCurrent,
        searchHitForeground: theme.searchHitForeground,
      ),
      background: pick('terminal.background', base.background),
      chrome: pick('terminal.chrome', base.chrome),
      chromeBorder: pick('terminal.chrome_border', base.chromeBorder),
      chromeForeground: pick('terminal.chrome_foreground', base.chromeForeground),
      overlay: pick('terminal.overlay', base.overlay),
      keyboardAppearance: base.keyboardAppearance,
    );
  }

  final AppTextColors text;
  final AppStatusColors status;
  final MessagePalette message;
  final TerminalPalette terminal;
  final AppAccentColors accent;
  final AppSurfaceColors surface;
  final AppSyntaxColors syntax;

  /// 取当前主题的调色板。
  ///
  /// 主题里没注册时按当前 `ColorScheme` 现算一份，而不是 assert 崩掉：
  /// 大量 widget 测试只搭一个裸 `MaterialApp`，没有 `buildAppTheme`；
  /// 崩掉会让"改一处配色"变成"改四十个测试的挂载代码"。
  /// 现算出来的值同样走 `fromScheme` + 内置 spec，与生产路径同源，颜色不会错。
  static AppPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppPalette>() ??
        AppPalette.fromScheme(
          theme.colorScheme,
        ).overrideWith(builtinThemeColors(theme.colorScheme.brightness));
  }

  @override
  AppPalette copyWith({
    AppTextColors? text,
    AppStatusColors? status,
    MessagePalette? message,
    TerminalPalette? terminal,
    AppAccentColors? accent,
    AppSurfaceColors? surface,
    AppSyntaxColors? syntax,
  }) {
    return AppPalette(
      text: text ?? this.text,
      status: status ?? this.status,
      message: message ?? this.message,
      terminal: terminal ?? this.terminal,
      accent: accent ?? this.accent,
      surface: surface ?? this.surface,
      syntax: syntax ?? this.syntax,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) {
      return this;
    }
    // 换肤是整屏切换，逐字段插值没有意义（渐变中间态没人看得到），
    // 但 ThemeExtension 要求实现：超过中点就直接换到目标那一套。
    return t < 0.5 ? this : other;
  }
}
