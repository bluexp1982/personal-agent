import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

import '../design/app_palette.dart';
import '../design/app_tokens.dart';
import 'mobile_top_bar_glass.dart';
import 'mobile_top_bar_icons.dart';

// 调用方只 import 这一个文件就能同时拿到按钮与自绘图形枚举。
export 'mobile_top_bar_icons.dart' show MobileTopBarGlyph, MobileTopBarIcon;

/// 手机版页头圆钮的边长。
///
/// 与手机端原型一致：38 的圆 + 页头上下留白 12 / 4 正好凑成 54 的最小高度，
/// 触控面积也够（比 Material 默认 48 略小，但整枚都是命中区，不像 24dp
/// 方钮那样只靠中间那块）。
const double kMobileTopBarButtonSize = 38;

/// 紧凑版边长：只给「面板整页」那条 40dp 高的标签条。
///
/// 38 的圆塞进 40 高的标签条后，标签与按钮会互相挤到不可读；缩到 30 是
/// 这一处刻意的让步，视觉语言（玻璃圆钮）不变。
const double kMobileTopBarCompactSize = 30;

/// 圆钮图标的标准边长。
const double kMobileTopBarIconSize = 18;

/// 紧凑版图标边长。
const double kMobileTopBarCompactIconSize = 16;

/// 页头最小高度：12（上）+ 38（钮）+ 4（下）。
const double kMobileTopBarMinHeight = 54;

/// 页头左内边距。
const double kMobileTopBarSideInset = 12;

/// 页头右内边距。
const double kMobileTopBarEndInset = 8;

/// 相邻两枚动作之间的距离。
const double kMobileTopBarGap = 4;

/// 合并胶囊里两格之间的分隔线宽度。
///
/// 定宽布局（面板标签条）要把它算进占位宽度，否则合并后多出的 1dp 会把 Row
/// 撑破：两枚 compact 钮 30 + 30，加这条线就是 61。
const double kMobileTopBarGroupDividerWidth = 1;

/// 磨砂玻璃的模糊量。`ImageFilter` 建一次复用：每次 build 都 new 一个会让
/// 页头在滚动/重建时反复分配原生资源。
final ImageFilter _topBarBlur = ImageFilter.blur(sigmaX: 10, sigmaY: 10);

/// 页头标题样式（16 / w700 / 字距 -0.2）。
///
/// 页面标题统一走这里；会话页那种「图标 + 标题」按原型用
/// [mobileTopBarRowTitleStyle]（14 / w600）。
TextStyle mobileTopBarTitleStyle(BuildContext context, {bool dark = false}) {
  return TextStyle(
    fontSize: AppFontSize.lg,
    fontWeight: AppWeight.bold,
    letterSpacing: -0.2,
    color: dark ? AppColors.onAccent : AppPalette.of(context).text.primary,
  );
}

/// 页头里「图标 + 标题」那一行文字（会话页）。
TextStyle mobileTopBarRowTitleStyle(
  BuildContext context, {
  bool dark = false,
}) {
  return TextStyle(
    fontSize: AppFontSize.base,
    fontWeight: AppWeight.semiBold,
    height: AppLineHeight.tight,
    color: dark ? AppColors.onAccent : AppPalette.of(context).text.primary,
  );
}

/// 暖白液态玻璃圆钮。
///
/// 背板分两条路：开关打开时交给 `liquid_glass_widgets` 做真折射（背景按边缘
/// 曲率折入、边缘有镜面高光与色散）；关掉时回退原来的「半透明暖白底 + 10px
/// 背景模糊」，几何与外观逐像素不变（见 [mobileTopBarGlassEnabled]）。
///
/// 两种路径都保留强调色 1px 细边；按下时底色抬到 82%（由 `InkWell` 的
/// highlight 覆盖实现，不另起动画控制器）。图标颜色不写死：浅色主题把正文灰往
/// 强调色方向偏一点，深色主题直接用 `text.secondary`，媒体全屏（[dark]）改用
/// 白色系。
class MobileTopBarButton extends StatelessWidget {
  const MobileTopBarButton({
    super.key,
    this.icon,
    this.glyph,
    this.child,
    this.tooltip,
    this.onPressed,
    this.compact = false,
    this.dark = false,
    this.bare = false,
  }) : assert(
         icon != null || glyph != null || child != null,
         '图标、自绘图形或自定义内容必须给一个',
       );

  final IconData? icon;
  final MobileTopBarGlyph? glyph;

  /// 自定义内容（比如此刻正在跑的 14dp 进度圈）。
  final Widget? child;

  final String? tooltip;
  final VoidCallback? onPressed;
  final bool compact;

  /// 深色底变体：媒体全屏那条黑底 AppBar 用它，不铺暖白玻璃。
  final bool dark;

  /// 只画命中区与内容，不画自己的玻璃底。
  ///
  /// 专供 [MobileTopBarButtonGroup]：胶囊底、描边与模糊由整组画一次，
  /// 组内每枚只负责自己的水波纹与点击。菜单触发器（`AgentMenu`）也走这一档，
  /// 这样它才能作为胶囊里的一格参与排布。
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final size = compact ? kMobileTopBarCompactSize : kMobileTopBarButtonSize;
    final glass = _glassOf(context, dark: dark);
    final content = _content(
      icon: icon,
      glyph: glyph,
      child: child,
      color: glass.icon,
      compact: compact,
    );

    final tapSurface = SizedBox(
      width: size,
      height: size,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          highlightColor: glass.press,
          splashColor: glass.press,
          child: Center(child: content),
        ),
      ),
    );

    // 玻璃路径与回退路径共用同一份 `_glassOf` 配色：玻璃自己算折射与边缘光，
    // 内容层只补一层极淡的 scrim（[glass.scrim]）与强调色细边，保证 18dp 图标
    // 在深浅背景上都读得清；回退路径仍用原来那层 0.52 的暖白。
    final plate = !bare && mobileTopBarGlassEnabled
        ? mobileTopBarGlassBackplate(
            context: context,
            // 玻璃路径不再套 `_topBarBlur`：再模糊一层会把折射盖掉。
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: glass.scrim,
                border: Border.all(color: glass.border),
              ),
              child: tapSurface,
            ),
            shape: MobileTopBarGlassShape.circle,
            height: size,
            tint: glass.fill,
            dark: dark,
          )
        : null;

    Widget surface;
    if (bare) {
      surface = tapSurface;
    } else if (plate != null) {
      surface = SizedBox(width: size, height: size, child: plate);
    } else {
      surface = SizedBox(
        width: size,
        height: size,
        child: ClipOval(
          child: BackdropFilter(
            filter: _topBarBlur,
            // 用 `DecoratedBox` 而不是 `Container`：后者的 decoration 会把
            // 1px 边框算成内边距，38 的命中区会缩成 36。
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: glass.fill,
                border: Border.all(color: glass.border),
              ),
              child: tapSurface,
            ),
          ),
        ),
      );
    }

    if (tooltip != null) {
      surface = Tooltip(message: tooltip!, child: surface);
    }
    return surface;
  }
}

/// 两枚（或三枚）动作并成一枚 38 高的胶囊，中间 1px × 18 分隔线。
///
/// 页头里相邻的 ≥2 枚圆钮必须走这一层：两枚各自带一层背板，交界处会看到两条
/// 折射边缘叠在一起，像一颗胶囊中间裂了条缝；整组只建一层（玻璃或旧的模糊层），
/// 胶囊才是完整的一颗。
///
/// [children] 里的每一格都要是 `MobileTopBarButton(bare: true)`（或包着它的
/// `AgentMenu`）：底、描边与裁剪由整组负责，格子里只留命中区与水波纹。
/// 这样菜单触发器也能作为胶囊里的一格，不必为它单开一种排布。
///
/// 组内严禁逐格再建玻璃层。`compact` / `dark` 必须与格子里的 `bare` 按钮一致，
/// 否则会出现「胶囊里再套一颗玻璃」。
class MobileTopBarButtonGroup extends StatelessWidget {
  const MobileTopBarButtonGroup({
    super.key,
    required this.children,
    this.dark = false,
    this.compact = false,
  }) : assert(children.length >= 2, '只有一枚动作时请直接用 MobileTopBarButton');

  final List<Widget> children;
  final bool dark;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final glass = _glassOf(context, dark: dark);
    final height = compact ? kMobileTopBarCompactSize : kMobileTopBarButtonSize;
    final radius = BorderRadius.circular(AppRadius.pill);

    // 同单枚按钮：`DecoratedBox` 不会把 1px 描边算成内边距，两格 38 并起来
    // 才正好是 77（38 + 1 + 38）。染色只在内容层：玻璃路径用极淡的 scrim，
    // 回退路径仍是原来那层 0.52 的暖白。
    Widget body(Color color) => DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: radius,
        border: Border.all(color: glass.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0)
              Container(
                width: kMobileTopBarGroupDividerWidth,
                height: 18,
                color: glass.divider,
              ),
            children[i],
          ],
        ],
      ),
    );

    final plate = mobileTopBarGlassEnabled
        ? mobileTopBarGlassBackplate(
            context: context,
            child: body(glass.scrim),
            shape: MobileTopBarGlassShape.capsule,
            height: height,
            tint: glass.fill,
            dark: dark,
          )
        : null;

    return SizedBox(
      height: height,
      child:
          plate ??
          ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: _topBarBlur,
              child: body(glass.fill),
            ),
          ),
    );
  }
}

/// 返回钮：自绘 chevron + `maybePop`，tooltip 仍是「返回」。
class MobileTopBarBackButton extends StatelessWidget {
  const MobileTopBarBackButton({
    super.key,
    this.dark = false,
    this.compact = false,
    this.tooltip = '返回',
    this.onPressed,
  });

  final bool dark;

  /// 紧凑版（30 / 16）：给 40 高的面板标签条用。
  final bool compact;
  final String tooltip;

  /// 不传就 `Navigator.maybePop()`；个别页面要自己决定退到哪儿时再覆盖。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return MobileTopBarButton(
      glyph: MobileTopBarGlyph.back,
      tooltip: tooltip,
      dark: dark,
      compact: compact,
      onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
    );
  }
}

/// 手机版页头：把原型几何套在 Material `AppBar` 上。
///
/// 为什么不自己画一整行：状态栏 padding、标题省略、`Scaffold` 语义、键盘
/// 避让、`find.byType(AppBar)` 这类既有断言都在 AppBar 里，重画等于把这些
/// 逐个补一遍，18 个页面很难不漏。
///
/// 内边距 12 / 8 / 上下 12 / 4 的拟合方式：AppBar 只做垂直居中，给
/// leading 与 actions 各加 `Padding(top: 8)`，46 高的内容居中后落在
/// 12 / 4 的位置（4 + 8 = 12）。
class MobileAppBar extends StatelessWidget implements PreferredSizeWidget {
  const MobileAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.leading,
    this.showBack = true,
    this.actions = const <Widget>[],
    this.dark = false,
    this.backgroundColor,
    this.bottom,
    this.titleSpacing,
  });

  final String? title;

  /// 自定义标题（会话页的「图标 + 标题」行）。
  final Widget? titleWidget;

  /// 自定义 leading。不传且 [showBack] 为真时用 [MobileTopBarBackButton]。
  final Widget? leading;

  final bool showBack;
  final List<Widget> actions;
  final bool dark;
  final Color? backgroundColor;
  final PreferredSizeWidget? bottom;

  /// 标题区左内边距。不传时按有无返回钮推导（无返回 12、有返回 0）。
  ///
  /// 传 0 是给"标题区要铺满整宽"的页面用的（通话页要把中间那枚胶囊
  /// 精确落在页宽中线上）：那时标题与右侧按钮都自带内边距。
  final double? titleSpacing;

  @override
  Size get preferredSize => Size.fromHeight(
    kMobileTopBarMinHeight + (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final leadingWidget =
        leading ?? (showBack ? MobileTopBarBackButton(dark: dark) : null);
    final titleStyle = mobileTopBarTitleStyle(context, dark: dark);

    return AppBar(
      toolbarHeight: kMobileTopBarMinHeight,
      // 状态栏那行时间 / 信号由系统画，明暗必须显式声明：`AppBar` 不传时
      // 会按 `backgroundColor` 估明暗，而这里的底色是**透明**——`estimateBrightnessForColor`
      // 把透明黑算成深色，于是两种主题都推成白色图标（浅色主题下白底白字）。
      systemOverlayStyle: _statusBarOverlayStyle(context, dark: dark),
      // 页头不要自己的底色：内容区的渐变/栏底要能透上来。
      backgroundColor: backgroundColor ?? Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      automaticallyImplyLeading: false,
      // 有返回时 54 的 leadingWidth 已经含了 4 的间隙，标题紧贴其后；
      // 没有返回的页面（设置 / 消息）标题回到 12 的内容线。
      titleSpacing:
          titleSpacing ?? (leadingWidget == null ? kMobileTopBarSideInset : 0),
      leadingWidth: leadingWidget == null
          ? 0
          : kMobileTopBarSideInset + kMobileTopBarButtonSize + kMobileTopBarGap,
      leading: leadingWidget == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(
                left: kMobileTopBarSideInset,
                right: kMobileTopBarGap,
                top: 8,
              ),
              child: Align(alignment: Alignment.center, child: leadingWidget),
            ),
      title:
          titleWidget ??
          (title == null
              ? null
              : Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                )),
      titleTextStyle: titleStyle,
      iconTheme: IconThemeData(
        size: kMobileTopBarIconSize,
        color: dark ? AppColors.onAccent : palette.text.secondary,
      ),
      actions: actions.isEmpty
          ? null
          : <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButtonTheme(
                  // 页头里偶尔还要放文字动作（「管理」「接受 N 条」「完成」）：
                  // 统一压成 38 高、胶囊描边、10 的左右内边距，才不会和圆钮
                  // 摆在同一行时一高一矮、各带一圈 Material 默认留白。
                  data: TextButtonThemeData(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, kMobileTopBarButtonSize),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: const StadiumBorder(),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: actions,
                  ),
                ),
              ),
              const SizedBox(width: kMobileTopBarEndInset),
            ],
      bottom: bottom,
    );
  }
}

/// 页头玻璃的配色。深浅主题与「黑底查看器」各一套，全部由 token 派生。
@immutable
class _Glass {
  const _Glass({
    required this.fill,
    required this.scrim,
    required this.border,
    required this.icon,
    required this.press,
    required this.divider,
  });

  /// 回退路径（`BackdropFilter`）的底色：要靠它自己压住底下的内容。
  final Color fill;

  /// 玻璃路径内容层的底色：折射由 shader 负责，这里只补极淡一层保证图标对比度。
  ///
  /// 不能复用 [fill]：0.52 的暖白会把折射与色散整块盖掉，看起来就只是"一层更透
  /// 的磨砂"，等于没升级。
  final Color scrim;

  final Color border;
  final Color icon;
  final Color press;
  final Color divider;
}

/// 状态栏内容（时间 / 信号 / 电量）该用深色还是浅色的那一份声明。
///
/// 两套字段都要给：iOS 读的是 [SystemUiOverlayStyle.statusBarBrightness]
/// （描述**背景**明暗，与内容相反），Android 读的是
/// [SystemUiOverlayStyle.statusBarIconBrightness]（描述**图标**明暗）。
///
/// 刻意不用 `SystemUiOverlayStyle.dark` / `.light` 整包预设：那两个还带着
/// `systemNavigationBarColor: 0xFF000000`，会把 Android 的导航栏刷成黑色。
/// 这里只动状态栏三项，形状对齐 Flutter 自己按 `AppBar` 底色推导出来的那份。
///
/// 明暗取 [Theme] 解析后的值而不是设备亮度：个性主题包可以固定浅色而系统是深色，
/// 状态栏得跟着**页面**走。
SystemUiOverlayStyle _statusBarOverlayStyle(
  BuildContext context, {
  required bool dark,
}) {
  // `dark` 是页头自己的"压在深色底上"（媒体全屏查看器），与主题明暗取或：
  // 黑底页面即使处在浅色主题下也必须用浅色图标。
  final light = dark || Theme.of(context).brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    // 与 `AppBar` 在 M3 下推导给状态栏的底色一致：透明，由页面渐变透上来。
    statusBarColor: Colors.transparent,
    statusBarBrightness: light ? Brightness.dark : Brightness.light,
    statusBarIconBrightness: light ? Brightness.light : Brightness.dark,
  );
}

_Glass _glassOf(BuildContext context, {required bool dark}) {
  final scheme = Theme.of(context).colorScheme;
  final palette = AppPalette.of(context);

  if (dark) {
    // 媒体全屏：黑底上的暖白玻璃会发脏，改成"淡淡的白色磨砂 + 白图标"。
    return _Glass(
      fill: AppColors.onAccent.withValues(alpha: 0.14),
      scrim: AppColors.onAccent.withValues(alpha: 0.06),
      border: AppColors.onAccent.withValues(alpha: 0.22),
      icon: AppColors.onAccent.withValues(alpha: 0.92),
      press: AppColors.onAccent.withValues(alpha: 0.26),
      divider: AppColors.onAccent.withValues(alpha: 0.22),
    );
  }

  final isDark = scheme.brightness == Brightness.dark;
  final accent = palette.accent.projectStart;
  return _Glass(
    // 深色主题用更高一点的不透明度：0.52 的白在深底上会糊成一层雾。
    fill: scheme.surface.withValues(alpha: isDark ? 0.58 : 0.52),
    // 玻璃自己会染色（见 `mobile_top_bar_glass.dart`），内容层再压一层 0.06~0.10
    // 的雾就够；再高会把边缘的色散与折射一起盖掉。
    scrim: scheme.surface.withValues(alpha: isDark ? 0.10 : 0.06),
    border: accent.withValues(alpha: 0.18),
    // 原型图标是暖灰 (#6B6259)：把正文灰往强调色偏一点，不新增色值。
    icon: isDark
        ? palette.text.secondary
        : Color.lerp(palette.text.secondary, accent, 0.22)!,
    press: scheme.surface.withValues(alpha: 0.82),
    divider: accent.withValues(alpha: 0.16),
  );
}

/// 圆钮/胶囊里的图形：自定义内容 > 自绘 > Material 图标。
Widget _content({
  required IconData? icon,
  required MobileTopBarGlyph? glyph,
  required Widget? child,
  required Color color,
  required bool compact,
}) {
  if (child != null) {
    return child;
  }
  final size = compact
      ? kMobileTopBarCompactIconSize
      : kMobileTopBarIconSize;
  if (glyph != null) {
    return MobileTopBarIcon(glyph: glyph, color: color, size: size);
  }
  return Icon(icon, size: size, color: color);
}
