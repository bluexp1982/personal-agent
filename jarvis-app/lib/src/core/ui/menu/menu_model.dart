import 'package:flutter/material.dart';

import '../../design/app_palette.dart';
import '../../design/app_tokens.dart';

/// 全站菜单的唯一样式来源。
///
/// 面板、行、触发器三层的尺寸与颜色都从这里取：以后想调圆角、悬停色、行高，
/// 只改这一处，输入栏三个下拉、左栏视图选项、模式下拉、各处「⋯」与标签右键
/// 会一起变——不再有"某个入口自己写死一套"的漏网之鱼。
///
/// 为什么不用 `showMenu` / `PopupMenuButton`：它们的悬停高亮是系统默认的淡色
/// 矩形，拿不到这里"浅灰圆角块 + 字色不变"的观感，也没法自然插分组标题与
/// 行尾说明。`MenuAnchor` + `MenuItemButton` 的 ButtonStyle 能按状态给底色，
/// 而定位、点外部关闭、Esc、上下键遍历、越界夹取全部是现成的。

/// 菜单里的一项：只描述"长什么样、点了回什么值"，不含业务语义。
///
/// 同一个模型覆盖全站所有菜单形态，组件按字段自动选行：
/// 有 [submenu] → 二级子菜单行；有 [subtitle] → 两行富文本行；
/// 有 [alias] / [description] → 命令行；其余 → 选项行。
/// 「有哪种字段就长成哪一行」写死在这里，调用方不需要挑预设，
/// 也就不可能出现两套风格并存。
@immutable
class AgentMenuItem<T> {
  const AgentMenuItem({
    this.value,
    required this.label,
    this.icon,
    this.leading,
    this.alias,
    this.description,
    this.subtitle,
    this.badge,
    this.selected = false,
    this.enabled = true,
    this.dividerBefore = false,
    this.key,
    this.submenu,
    this.submenuValue,
    this.submenuWidth,
    this.labelSize,
    this.labelWeight,
    this.selectedColor,
    this.onSelected,
  });

  /// 回传给 [AgentMenu.onSelected] 的标识。
  ///
  /// 二级子菜单行不需要值（点了只会展开下一层），所以允许为空；
  /// 其余行都应当给一个。
  final T? value;

  final String label;

  /// 行首图标。缺省时不占位——没图标的条目就该从左边缘起排。
  final IconData? icon;

  /// 自定义行首控件，优先于 [icon]。
  ///
  /// 模式下拉的「渐变色块」没法用 [IconData] 表达（它是渐变底 + 白图标），
  /// 但又必须和别的菜单共用同一行结构，于是留一个 Widget 口子。
  final Widget? leading;

  /// 紧跟中文名的英文别名（`file` / `compact`），比正文再淡一档。
  final String? alias;

  /// 行尾右对齐的一句用途说明。
  final String? description;

  /// 第二行副标题。给了它就渲染成"标题 + 一句说明"的两行富文本行。
  final String? subtitle;

  /// 行尾小徽标（如「自动审查」的 EXP）。
  final String? badge;

  /// 当前选中项：行尾打勾。
  final bool selected;

  /// 是否可选。禁用项仍然显示（淡到 45%），只是点不动。
  final bool enabled;

  /// 与上一项之间插一条分隔线，用来表达分组。
  ///
  /// 第一项上的这个标记会被忽略：菜单顶部不需要一根悬空的线。
  final bool dividerBefore;

  /// 供测试与无障碍定位的稳定 Key（文案会改，Key 不会）。
  ///
  /// 挂在整行可点区域的 [MenuItemButton] 上：测试既能 `tap` 它，
  /// 也能把它读成 `MenuItemButton` 校验 `onPressed`。
  final Key? key;

  /// 非空则渲染成「标题 + 当前值 + ›」的行，点开向右再长一层。
  final List<AgentMenuGroup<T>>? submenu;

  /// 二级子菜单行右侧显示的当前值。
  final String? submenuValue;

  /// 二级浮层宽度。缺省沿用一级面板宽度。
  final double? submenuWidth;

  /// 主文案字号。缺省取 [AppFontSize.base]（命令行与选项行同档）。
  final double? labelSize;

  /// 主文案字重。模式下拉要 w600，其余保持 bodyMedium 的 w400。
  final FontWeight? labelWeight;

  /// 勾选色。缺省走 [AgentMenuStyle.selectedMarkColorOf]（全站同一档），
  /// 只有模式下拉这类需要强调的调用方才显式覆盖。
  final Color? selectedColor;

  /// 单项级回调，优先于 [AgentMenu.onSelected]。
  ///
  /// 模型菜单的一级浮层里挂着两个二级列表，选「模型」和选「推理等级」
  /// 要走不同的分发；把它们塞进同一个组件级回调只能靠值的形状猜，
  /// 不如让每一项自己带一个。
  final ValueChanged<T>? onSelected;
}

/// 菜单里的一组：可选的标题 + 若干条目。
///
/// 模式菜单与输入栏「+」需要分组标题；各处「⋯」只需一个无标题分组，
/// 由组件把 `title == null` 的行渲染成连续的行列表。
@immutable
class AgentMenuGroup<T> {
  const AgentMenuGroup({
    this.title,
    this.dividerBefore = false,
    required this.items,
  });

  final String? title;

  /// 与上一组之间插一条分隔线。第一组上的标记会被忽略。
  final bool dividerBefore;

  final List<AgentMenuItem<T>> items;
}

abstract final class AgentMenuStyle {
  // -------------------------------------------------------------------------
  // 面板
  // -------------------------------------------------------------------------

  /// 面板圆角。Codex 的浮层比 M3 默认的 4dp 圆得多，但不到胶囊那一步。
  static const double panelRadius = 12;

  /// 面板内边距：条目自己的圆角块离面板边缘留一点缝，才有"一叠纸条"的层次。
  static const double panelPadding = 6;

  /// 面板最小宽度。
  ///
  /// 菜单是一列短词，宽度本会跟着最长的文案走；太窄时「关闭其他标签页」这种
  /// 长项会直接顶到面板边缘，看着像被挤扁了。220 让它两侧都留得出呼吸，
  /// 与 Codex 的右键菜单量级一致。
  ///
  /// 注意：`MenuStyle.minimumSize` 对竖向菜单**不生效**——`_MenuPanel` 外面
  /// 套了一层 `IntrinsicWidth`，它用内容的固有宽度把子级收紧，绕过了菜单样式
  /// 里的最小宽度。真正兜底的是 [itemMinWidth] 与每条行自己的 `SizedBox`。
  static const double panelMinWidth = 220;

  /// 面板最大高度：再长就滚动。与旧实现一致，避免浮层长到出屏。
  static const double panelMaxHeight = 420;

  // -------------------------------------------------------------------------
  // 行
  // -------------------------------------------------------------------------

  /// 行左右内边距。内容宽的换算与它绑定（见 [contentWidthOf]）。
  static const double itemHorizontalPadding = 8;

  /// 条目圆角：悬停块是圆角矩形而不是整行色带。
  static const double itemRadius = 8;

  /// 单行条目最小高度（命令行 32 / 选项行 34 自己再给 `SizedBox`）。
  static const double itemMinHeight = 32;

  /// 单行条目最大高度。超过就会被 `MenuItemButton` 裁掉，所以两行富文本行
  /// 要另外放宽（见 [richRowMaxHeight]）。
  static const double itemMaxHeight = 40;

  /// 两行富文本行的最大高度：模式下拉的「色块 + 模式名 + 一句用途」用它。
  static const double richRowMaxHeight = 64;

  /// 条目最小宽度 = 面板最小宽度 − 面板左右内边距。
  ///
  /// 这是最小宽度的实际执行者：每个条目自己套一层固定宽度，
  /// 固有宽度被抬到这条线上，外层 `IntrinsicWidth` 量出来的面板自然也就够宽了。
  static const double itemMinWidth = panelMinWidth - panelPadding * 2;

  /// 子菜单行右侧内边距。
  ///
  /// 普通行是 [itemHorizontalPadding]（8dp）；子菜单行的折角已经贴到行尾，
  /// 再留 8 会让右侧空出一截，这里单独收到 0（面板自身的 padding 仍在）。
  static const double submenuTrailingEndPadding = 0;

  /// 折角在 trailing 槽位内的左移量。
  ///
  /// 该槽位宽 12（SDK 的 `start` padding）+ 16（[iconSize]）；图标左移 4 后
  /// 绘制范围仍在槽位内，不会被 `Expanded > ClipRect` 裁掉，同时把
  /// 「当前值 → 折角」的间距从 12dp 收到 8dp。
  static const double submenuChevronInset = 4;

  /// `SubmenuButton` 右侧 trailing 槽位额外占掉的宽度。
  ///
  /// = 12（SDK 给折角的 start padding）+ 16（折角图标宽）
  ///   − (8 − 0)（子菜单行右内边距比普通行少掉的部分）
  /// = 20。
  ///
  /// 不抵掉它，带二级菜单的行会比普通行宽一截：`MenuAnchor` 按配置宽度算位置
  /// 与越界夹取、却按实际宽度绘制，浮层贴到窗口右沿时最外侧那一条
  /// （正好是 1px 描边 + 投影）会被 Overlay 裁掉，看起来就是"少一条边、也没阴影"。
  static const double submenuArrowInset =
      12 + iconSize - (itemHorizontalPadding - submenuTrailingEndPadding);

  /// 命令行高度、字号与图标尺寸。
  ///
  /// 字号不再就地写数，而是指向 [AppFontSize] 的五档：
  /// 命令行主文案与选项行同为 `base`，别名/说明落 `sm`，徽标落 `xs`。
  ///
  /// **全站菜单的字号规则**：一个菜单项只有一档主文案（`base`），所有附属文字
  /// （别名、行尾说明、副标题、子菜单当前值、徽标）都小一档（`sm` / `xs`）。
  /// 新增行形态时照此取值，不要让某个形态的次文案和主文案同号。
  static const double commandRowHeight = 32;
  static const double commandLabelSize = AppFontSize.base;
  static const double commandIconSize = 15;
  static const double aliasSize = AppFontSize.sm;
  static const double descriptionSize = AppFontSize.sm;

  /// 选项行高度、字号、图标与徽标尺寸。
  static const double optionRowHeight = 34;
  static const double optionLabelSize = AppFontSize.base;
  static const double iconSize = 16;
  static const double badgeSize = AppFontSize.xs;

  /// 二级子菜单行里右侧当前值的字号。
  ///
  /// 与两行富文本行的副标题、命令行的别名/说明同一档（[AppFontSize.sm]）：
  /// 菜单项的**主文案一律 `base`，次文案一律小一档**——这是全站菜单的层级规则，
  /// 不是某个面板自己的选择。当前值只是"现在是什么"的提示，不该和标题一样重。
  static const double submenuValueSize = AppFontSize.sm;

  /// 富文本行（模式下拉）副标题字号。
  static const double subtitleSize = AppFontSize.sm;

  // -------------------------------------------------------------------------
  // 触发器
  // -------------------------------------------------------------------------

  static const double triggerRadius = 10;

  /// 触发器行首图标的占位框边长。
  ///
  /// 与权限菜单项的行首图标共用同一块 18×18 画布：触发器与展开后的同一项
  /// 必须是同一视觉大小，占位不同会让图标在开合之间跳一下。
  static const double triggerIconBox = 18;

  /// 浮层与触发器之间的竖直缝隙：紧一点更像"从按钮里长出来"，
  /// 松了会像独立对话框。
  static const double triggerGap = 6;

  /// 右对齐浮层的偏移：把面板整个左移一个面板宽。
  ///
  /// `MenuAnchor` 只会把面板的左上角放在对齐点上，所以「面板右边缘贴着触发器
  /// 右边缘」只能靠自己减一个宽度；贴窗口右沿的入口（模型胶囊）必须这么做，
  /// 否则最外侧那 1px 描边与 16dp 投影会被 Overlay 裁掉。
  static Offset rightAlignedOffset(double panelWidth) =>
      Offset(-panelWidth, triggerGap);

  /// 触发器悬停 / 展开时的底色强度。透明态用同一个颜色的 0 透明度而不是
  /// `Colors.transparent`：后者是透明黑，插值时会出现一段偏暗的灰。
  ///
  /// 0.43 叠在输入栏白面板上约等于 `#F2F3F4`：参考客户端里那枚胶囊的悬停底。
  /// 再高就成了一块明显的灰砖——这些入口要"浮起来"，不是"被选中"。
  static const double triggerHighlightAlpha = 0.43;

  /// 圆形图标触发器（「+」）常驻时的底色：比悬停再淡一档，约 `#F5F5F7`。
  ///
  /// 两个强度都取自同一个 `surfaceContainerHighest`，只是 alpha 不同——
  /// 不新增颜色，也不让「+」在常态下比胶囊的悬停底还深。
  static const double triggerRestAlpha = 0.33;

  /// 折角箭头翻转。
  ///
  /// 只有这一处动画：条目高亮是"当帧到位"的，悬停不该有跟随动画。
  static const Duration triggerChevronDuration = Duration(milliseconds: 160);
  static const Curve triggerChevronCurve = Curves.easeOutCubic;

  // -------------------------------------------------------------------------
  // 换算
  // -------------------------------------------------------------------------

  /// 条目内容宽 = 面板宽 − 面板内边距 ×2 − 条目左右内边距 ×2。
  ///
  /// 宽度必须兜在条目上：菜单面板外面套着 `IntrinsicWidth`，它在量固有宽度时
  /// 会把样式里的 `minimumSize` 绕过去，只给 `minimumSize` 是不够的。
  static double contentWidthOf(double panelWidth) =>
      panelWidth - panelPadding * 2 - itemHorizontalPadding * 2;

  /// 二级子菜单行的内容宽：还要再抵掉 [submenuArrowInset]。
  static double submenuRowWidthOf(double panelWidth) =>
      contentWidthOf(panelWidth) - submenuArrowInset;

  // -------------------------------------------------------------------------
  // 样式
  // -------------------------------------------------------------------------

  /// 面板容器样式。
  static MenuStyle panelStyleOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll<Color>(scheme.surface),
      // M3 默认会给表面叠一层主色调（surfaceTint），在浅色主题下会把白浮层
      // 染成灰蓝；这里的层级靠阴影表达，不要那层染色。
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      shadowColor: WidgetStatePropertyAll<Color>(
        scheme.shadow.withValues(alpha: 0.18),
      ),
      elevation: const WidgetStatePropertyAll<double>(16),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(panelPadding),
      ),
      minimumSize: const WidgetStatePropertyAll<Size>(Size(panelMinWidth, 0)),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
    );
  }

  /// 条目样式：浅灰悬停块 + 正文颜色不变。
  ///
  /// 全站唯一的一套行样式。曾经还有一套"主色块 + 白字"，两套并存时同一份
  /// 「关闭 / 重命名 / 删除」在两个入口长得不一样；统一成这一套后，
  /// 带分组标题、英文别名与行尾说明的浮层与右键菜单终于是同一个东西。
  static ButtonStyle rowStyleOf(
    BuildContext context, {
    double minHeight = itemMinHeight,
    double maxHeight = itemMaxHeight,
    bool highlighted = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return MenuItemButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: itemHorizontalPadding),
      minimumSize: Size(0, minHeight),
      maximumSize: Size(double.infinity, maxHeight),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      // 悬停高亮当帧到位：200ms 的缓动会让鼠标扫过时「慢半拍」。
      animationDuration: Duration.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(itemRadius),
      ),
    ).copyWith(
      backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        // `highlighted` 是调用方自己维护的"当前键盘选中行"：没有 `MenuAnchor`
        // 遍历时（比如输入栏的 `@` 候选），`focused` 不会落在行上，
        // 只能由外部把这一行点亮，否则按方向键看不出任何变化。
        final active =
            highlighted ||
            states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused) ||
            states.contains(WidgetState.pressed);
        if (!active) {
          // 非悬停态给「同色的 0 透明度」而不是 `Colors.transparent`，
          // 避免状态插值时经过一段偏暗的透明黑。
          return scheme.onSurface.withValues(alpha: 0);
        }
        return scheme.surfaceContainerHighest.withValues(alpha: 0.9);
      }),
      // 桌面端靠悬停定位，默认的按压水波纹会把圆角块糊成一片色。
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    );
  }

  /// 旧名保留：输入栏三个浮层与左栏视图选项一直用它。
  static ButtonStyle subtleRowStyleOf(BuildContext context) =>
      rowStyleOf(context);

  /// 全站菜单勾选标记的唯一颜色口径。
  ///
  /// 勾选回答的是"现在用的是哪个"，比正文淡一档即可。之前选项行用
  /// `tertiary`、两行富文本行用 `secondary`，同一份清单换个入口就变深变浅；
  /// 收敛到这一档后，新增行形态直接调用它，不再各写默认值。
  static Color selectedMarkColorOf(BuildContext context) =>
      AppPalette.of(context).text.secondary;

  /// 行内文字。必须挂在 `textTheme.bodyMedium`（w400）上再 copyWith：
  /// 裸 `TextStyle` 会继承 `MenuItemButton` 内层 `labelLarge` 的 w500，
  /// 同级条目会显得"粗一档"。
  static TextStyle? labelStyleOf(
    BuildContext context, {
    required double fontSize,
    Color? color,
    FontWeight? weight,
  }) {
    return Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontSize: fontSize,
      height: AppLineHeight.tight,
      color: color,
      fontWeight: weight,
    );
  }
}

/// 浮层里的分组标题。不是按钮：`MenuAnchor` 的键盘遍历会自然跳过。
///
/// 输入栏浮层（`添加` / `指令` / `DeepSeek`）、左栏「视图选项」
/// （`分组方式` / `排序方式` / `筛选会话`）与模式下拉共用。
class AgentMenuSectionHeader extends StatelessWidget {
  const AgentMenuSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 4),
      child: Text(
        title,
        // 同样要挂 `bodyMedium`（w400）：裸 `TextStyle` 会继承外面
        // `MenuItemButton` 的 `labelLarge`（w500），分组标题会显得发粗。
        style: theme.bodyMedium?.copyWith(
          fontSize: AppFontSize.sm,
          height: AppLineHeight.tight,
          letterSpacing: AppLetterSpacing.tight,
          color: palette.text.tertiary,
        ),
      ),
    );
  }
}

/// 菜单里的分组线：一条 1px 细线，上下留白由高度给出。
///
/// 用普通 widget 而不是 `PopupMenuDivider`：`MenuAnchor` 的键盘遍历只认按钮，
/// 非按钮 widget 会被自然跳过，不会出现"按上下键停在一条线上"。
class AgentMenuDivider extends StatelessWidget {
  const AgentMenuDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Divider(
      height: 9,
      thickness: 1,
      indent: 4,
      endIndent: 4,
      color: scheme.outlineVariant.withValues(alpha: 0.5),
    );
  }
}
