import 'package:flutter/material.dart';

import '../../design/app_palette.dart';
import '../../design/app_text_styles.dart';
import '../../design/app_tokens.dart';
import 'menu_model.dart';

/// 菜单里的四种行与三种触发器。
///
/// 行与触发器只吃 [AgentMenuItem] 的展示字段，不碰业务：
/// 点了做什么由 [AgentMenu] 传进来的回调决定。想调行高、字号、悬停色，
/// 改 [AgentMenuStyle]；这里只负责把令牌摆到正确的位置上。

// ---------------------------------------------------------------------------
// 行
// ---------------------------------------------------------------------------

/// 「图标 + 中文名 + 英文别名 + 行尾说明」的一行，给「+」菜单那种命令行用。
///
/// 高度 32（含上下各 1dp 留缝是 34）：这一行要同时塞英文别名与一句用途，
/// 比 34 的选项行矮一点，两行并排时视觉才不散。
class AgentMenuCommandRow extends StatelessWidget {
  const AgentMenuCommandRow({
    super.key,
    this.buttonKey,
    required this.item,
    required this.width,
    this.onPressed,
    this.highlighted = false,
  });

  /// 挂在 [MenuItemButton] 上的稳定 Key：测试既要 `tap` 它，也要把它
  /// 读成 `MenuItemButton` 校验 `onPressed`。
  final Key? buttonKey;

  final AgentMenuItem<Object?> item;

  /// 条目内容宽（已扣掉面板与条目内边距），由 [AgentMenuStyle.contentWidthOf] 算。
  final double width;
  final VoidCallback? onPressed;

  /// 当前键盘选中这一行。
  ///
  /// 与 [AgentMenuItem.selected] 不同：那个表示"现在用的是哪个"（打勾），
  /// 这个是"光标停在哪"（整行底色）。没有 `MenuAnchor` 遍历的浮层
  /// （如输入栏 `@` 候选）只能靠外部驱动，否则按方向键看不出变化。
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final palette = AppPalette.of(context);
    final enabled = item.enabled;
    final labelColor = enabled ? palette.text.primary : palette.text.disabled;
    // 次级信息（别名、行尾说明）比正文再淡一档；淡是由色阶管的，不再叠 alpha。
    final subColor = enabled ? palette.text.tertiary : palette.text.disabled;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MenuItemButton(
        key: buttonKey,
        onPressed: enabled ? onPressed : null,
        // 悬停不抢焦点：划过菜单时焦点跟着跳，底色会在两层灰之间闪。
        requestFocusOnHover: false,
        style: AgentMenuStyle.rowStyleOf(context, highlighted: highlighted),
        child: SizedBox(
          width: width,
          height: AgentMenuStyle.commandRowHeight,
          child: Row(
            children: <Widget>[
              if (item.icon != null) ...<Widget>[
                Icon(
                  item.icon,
                  size: AgentMenuStyle.commandIconSize,
                  color: enabled
                      ? palette.text.secondary
                      : palette.text.disabled,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                item.label,
                maxLines: 1,
                style: theme.bodyMedium?.copyWith(
                  fontSize: item.labelSize ?? AgentMenuStyle.commandLabelSize,
                  height: AppLineHeight.tight,
                  color: labelColor,
                  fontWeight: item.labelWeight,
                ),
              ),
              if (item.alias != null) ...<Widget>[
                const SizedBox(width: 6),
                Text(
                  item.alias!,
                  maxLines: 1,
                  // 同样挂在 `bodyMedium`（w400）上：裸 `TextStyle` 会继承
                  // `MenuItemButton` 那层 `labelLarge` 的 w500。
                  style: theme.bodyMedium?.copyWith(
                    fontSize: AgentMenuStyle.aliasSize,
                    height: AppLineHeight.tight,
                    color: subColor,
                  ),
                ),
              ],
              if (item.description != null)
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      item.description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: theme.bodyMedium?.copyWith(
                        fontSize: AgentMenuStyle.descriptionSize,
                        height: AppLineHeight.tight,
                        color: subColor,
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「图标 + 名称（+ 徽标）+ 行尾勾选」的一行：单选类浮层的通用条目。
///
/// 权限、模型二级列表、左栏视图选项、各处「⋯」与浏览器来源都用它。
/// [leading] 优先于 [icon]，给模式下拉那种"图形不是 IconData"的入口留口子。
class AgentMenuOptionRow extends StatelessWidget {
  const AgentMenuOptionRow({
    super.key,
    this.buttonKey,
    required this.label,
    required this.width,
    required this.selected,
    required this.onPressed,
    this.icon,
    this.leading,
    this.badge,
    this.labelSize = AgentMenuStyle.optionLabelSize,
    this.labelWeight,
    this.height = AgentMenuStyle.optionRowHeight,
    this.enabled = true,
    this.selectedColor,
  });

  /// 挂在 [MenuItemButton] 上的稳定 Key（见 [AgentMenuCommandRow.buttonKey]）。
  final Key? buttonKey;

  final String label;

  /// 条目内容宽（已扣掉菜单面板与条目的内边距）。
  final double width;
  final bool selected;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? leading;
  final String? badge;
  final double labelSize;
  final FontWeight? labelWeight;
  final double height;
  final bool enabled;

  /// 勾选色。缺省比正文留一点存在感——它回答「现在用的是哪个」，
  /// 全部条目都置灰时更需要看得见。
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final palette = AppPalette.of(context);
    final labelColor = enabled ? palette.text.primary : palette.text.disabled;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MenuItemButton(
        key: buttonKey,
        onPressed: enabled ? onPressed : null,
        requestFocusOnHover: false,
        style: AgentMenuStyle.subtleRowStyleOf(context),
        child: SizedBox(
          width: width,
          height: height,
          child: Row(
            // 左侧一组靠左、勾选靠右：文案再长也不会把这一行顶出面板。
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (leading != null) ...<Widget>[
                      leading!,
                      const SizedBox(width: 8),
                    ] else if (icon != null) ...<Widget>[
                      Icon(
                        icon,
                        size: AgentMenuStyle.iconSize,
                        color: enabled
                            ? palette.text.secondary
                            : palette.text.disabled,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.bodyMedium?.copyWith(
                          fontSize: labelSize,
                          height: AppLineHeight.tight,
                          color: labelColor,
                          fontWeight: labelWeight,
                        ),
                      ),
                    ),
                    if (badge != null) ...<Widget>[
                      const SizedBox(width: 5),
                      Text(
                        badge!,
                        style: TextStyle(
                          fontSize: AgentMenuStyle.badgeSize,
                          height: AppLineHeight.tight,
                          letterSpacing: AppLetterSpacing.wide,
                          fontWeight: AppWeight.semiBold,
                          color: palette.text.tertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_rounded,
                  size: AgentMenuStyle.iconSize,
                  color:
                      selectedColor ?? AgentMenuStyle.selectedMarkColorOf(context),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「自定义行首 + 标题 + 一句说明 + 勾选」的两行行：模式下拉专用形态。
///
/// 与选项行的区别不是"另一套风格"，而是内容确实是两行：标题下面那句用途
/// 是这一项存在的理由（分段控件放不下它，才换成了下拉）。因此行高由内容撑开，
/// 只放宽 `maximumSize`——否则 40 的上限会把第二行裁掉。
class AgentMenuRichRow extends StatelessWidget {
  const AgentMenuRichRow({
    super.key,
    this.buttonKey,
    required this.label,
    required this.width,
    required this.selected,
    required this.onPressed,
    this.subtitle,
    this.leading,
    this.labelSize = AgentMenuStyle.optionLabelSize,
    this.labelWeight,
    this.enabled = true,
    this.selectedColor,
  });

  /// 挂在 [MenuItemButton] 上的稳定 Key（见 [AgentMenuCommandRow.buttonKey]）。
  final Key? buttonKey;

  final String label;
  final String? subtitle;

  /// 条目内容宽（已扣掉菜单面板与条目的内边距）。
  final double width;
  final bool selected;
  final VoidCallback? onPressed;

  /// 行首图形（模式下拉的渐变色块）。
  final Widget? leading;

  final double labelSize;
  final FontWeight? labelWeight;
  final bool enabled;
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = Theme.of(context).textTheme;

    return Padding(
      // 上下各留 1dp：默认底色铺满整块按钮，留缝后相邻两行的圆角才不会粘在一起。
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MenuItemButton(
        key: buttonKey,
        onPressed: enabled ? onPressed : null,
        // 悬停不抢焦点：默认会在悬停时 requestFocus，底色从 hover 灰跳到
        // focus 灰，看起来就是"闪一下、两种背景色"。
        requestFocusOnHover: false,
        style: AgentMenuStyle.rowStyleOf(
          context,
          maxHeight: AgentMenuStyle.richRowMaxHeight,
        ),
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.bodyMedium?.copyWith(
                        fontSize: labelSize,
                        fontWeight: labelWeight,
                        color: palette.text.primary,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.labelSmall?.copyWith(
                          fontSize: AgentMenuStyle.subtitleSize,
                          // 两行菜单的说明文字和行尾 description 同一档：
                          // 用 tertiary，避免副标题和主标题一样重。
                          color: palette.text.tertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (selected) ...<Widget>[
                const SizedBox(width: 6),
                Icon(
                  Icons.check_rounded,
                  size: AgentMenuStyle.iconSize,
                  color:
                      selectedColor ?? AgentMenuStyle.selectedMarkColorOf(context),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 一级浮层里「标题 + 当前值 + ›」那种行，点开是二级浮层。
///
/// 折角自己画在行尾：默认那个 `arrow_right` 会跟我们这枚挤在一起。
class AgentMenuSubmenuRow extends StatelessWidget {
  const AgentMenuSubmenuRow({
    super.key,
    this.buttonKey,
    required this.label,
    required this.value,
    required this.width,
    required this.menuWidth,
    required this.menuChildren,
  });

  /// 挂在 [SubmenuButton] 上的稳定 Key（见 [AgentMenuCommandRow.buttonKey]）。
  final Key? buttonKey;

  final String label;

  /// 右侧显示的当前值（模型名 / 推理等级）。
  final String value;

  /// 条目内容宽：调用方要传 [AgentMenuStyle.submenuRowWidthOf] 的结果。
  final double width;

  /// 二级浮层宽度。
  final double menuWidth;

  final List<Widget> menuChildren;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: SubmenuButton(
        key: buttonKey,
        // 二级浮层沿一级面板右侧展开（默认方向），视觉令牌与一级同一套。
        menuStyle: AgentMenuStyle.panelStyleOf(context).copyWith(
          minimumSize: WidgetStatePropertyAll<Size>(Size(menuWidth, 0)),
          maximumSize: WidgetStatePropertyAll<Size>(
            Size(menuWidth, AgentMenuStyle.panelMaxHeight),
          ),
        ),
        style: AgentMenuStyle.subtleRowStyleOf(context).copyWith(
          // 子菜单行右侧不留内边距：折角已经贴到行尾，再留 8 会空出一截。
          // 减掉的部分已经在 `submenuArrowInset` 里补偿，面板宽度不变。
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsetsDirectional.only(
              start: AgentMenuStyle.itemHorizontalPadding,
              end: AgentMenuStyle.submenuTrailingEndPadding,
            ),
          ),
        ),
        // 折角交给 SDK 的 trailing 槽位，不要自己画在 child 里：
        // `_MenuItemLabel` 会给 child 套一层 `Expanded > ClipRect`，画到布局盒
        // 之外（例如用 `Transform.translate`）会被整枚裁掉。
        // 该槽位天然靠右；图标在槽位内部左移 [AgentMenuStyle.submenuChevronInset]，
        // 把与当前值的间距从 12 收到 8，绘制范围仍在槽位内、不会被裁。
        // 尺寸必须显式给 16：SDK 会给它套 `IconTheme`，不写会回落成 24，把行宽撑出面板。
        submenuIcon: WidgetStatePropertyAll<Widget?>(
          Transform.translate(
            offset: const Offset(-AgentMenuStyle.submenuChevronInset, 0),
            child: Icon(
              Icons.chevron_right_rounded,
              size: AgentMenuStyle.iconSize,
              // 与主标题同色：它也是"这一行能往里走"的正文级提示。
              color: palette.text.primary,
            ),
          ),
        ),
        menuChildren: menuChildren,
        child: SizedBox(
          // 与选项行同高同字号：这两类行放在一起时不该有粗细/大小差。
          width: width,
          height: AgentMenuStyle.optionRowHeight,
          child: Row(
            children: <Widget>[
              // 主标题**不能**用 `Flexible`：它是 flex 子项，会与右侧的
              // `Expanded` 平分主轴宽度，当前值和折角就被挤到行中部去了。
              // 这里只用 `ConstrainedBox` 限一个最大宽度（不参与 flex 分配），
              // 让它按内容占位，剩余宽度全部留给右侧的当前值。
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // 必须挂在 `bodyMedium` 上再 copyWith：`SubmenuButton` 内部是
                  // `TextButton`，它的 DefaultTextStyle 是 `labelLarge`（w500）。
                  style: theme.bodyMedium?.copyWith(
                    fontSize: AgentMenuStyle.optionLabelSize,
                    height: AppLineHeight.tight,
                    color: palette.text.primary,
                  ),
                ),
              ),
              // 主标题与当前值之间必须留出间距：紧贴在一起会读成
              // "模型深度求索…"，分不出哪一段是标题、哪一段是当前值。
              const SizedBox(width: 12),
              // 当前值靠右吃满剩余宽度：长模型名放不下时截断的是它，
              // 而不是把这一行顶出面板。
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.bodyMedium?.copyWith(
                      fontSize: AgentMenuStyle.submenuValueSize,
                      height: AppLineHeight.tight,
                      color: palette.text.tertiary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 触发器
// ---------------------------------------------------------------------------

/// 折角箭头：收起朝下，展开时转半圈朝上。
///
/// 全站唯一的触发器动画。方向表达的是"点开 / 收起"，与面板从哪一侧弹开无关：
/// 输入栏与左栏的菜单都向上展开，箭头照样先朝下。
class AgentMenuChevron extends StatelessWidget {
  const AgentMenuChevron({
    super.key,
    required this.open,
    this.icon = Icons.expand_more_rounded,
    this.size = 14,
    this.color,
  });

  final bool open;
  final IconData icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: open ? 0.5 : 0,
      duration: AgentMenuStyle.triggerChevronDuration,
      curve: AgentMenuStyle.triggerChevronCurve,
      child: Icon(
        icon,
        size: size,
        color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 触发器的高亮底：平时完全透明，悬停或展开时浮出一块淡灰。
///
/// 透明态用同一个颜色的 0 透明度而不是 `Colors.transparent`：后者是透明**黑**，
/// 颜色插值时会经过一段偏暗的灰，看着就像闪了一下另一种底色。
class AgentMenuTriggerSurface extends StatelessWidget {
  const AgentMenuTriggerSurface({
    super.key,
    required this.child,
    this.height = 28,
    this.padding = const EdgeInsets.only(left: 7, right: 5),
    this.highlighted = false,
    this.highlightAlpha = AgentMenuStyle.triggerHighlightAlpha,
    this.radius = AgentMenuStyle.triggerRadius,
  });

  final Widget child;
  final double height;
  final EdgeInsetsGeometry padding;

  /// 悬停或展开。
  final bool highlighted;
  final double highlightAlpha;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(
          alpha: highlighted ? highlightAlpha : 0,
        ),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}

/// 胶囊触发器：可选图标 + 主文案 + 折角。
///
/// 权限（带图标）与模型两个入口共用；模式下拉与浏览器徽标形状不同
/// （渐变色块 / 淡色徽标），但它们的高亮底与折角仍来自
/// [AgentMenuTriggerSurface] 与 [AgentMenuChevron]，改一处即可同步。
class AgentMenuPill extends StatelessWidget {
  const AgentMenuPill({
    super.key,
    this.icon,
    this.iconSize = 15,
    this.iconScale = 1,
    required this.label,
    this.labelSize,
    required this.open,
    required this.hovering,
    this.chevron = Icons.expand_more_rounded,
    this.chevronSize = 14,
  });

  final IconData? icon;

  /// 行首图标的声明尺寸与视觉补偿。
  ///
  /// 缺省 15 / 1.0 保持其它入口不变；权限胶囊传 16 与菜单项同一套系数，
  /// 让触发器与展开后的同一项看起来一样大。
  final double iconSize;
  final double iconScale;
  final String label;

  /// 主文案字号：默认沿用 `AppText.rowSecondary` 的 12.5。
  ///
  /// 模型名这类纯英文标识在小一号上更贴近参考产品——英文的视觉重量比中文
  /// 轻，同号看起来会偏大。只覆盖字号，行高与颜色仍走同一份样式。
  final double? labelSize;

  final bool open;
  final bool hovering;
  final IconData chevron;
  final double chevronSize;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // 整枚胶囊固定用控件档：常驻、悬停、展开都不换色——颜色一变就像换了个控件。
    // 交互反馈只由 [AgentMenuTriggerSurface] 的悬停底表达，文字保持稳定。
    final foreground = palette.text.control;

    return AgentMenuTriggerSurface(
      highlighted: open || hovering,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            // 与菜单项共用同一块 18×18 占位：开合菜单时图标不跳位。
            SizedBox.square(
              dimension: AgentMenuStyle.triggerIconBox,
              child: Center(
                child: Transform.scale(
                  scale: iconScale,
                  child: Icon(icon, size: iconSize, color: foreground),
                ),
              ),
            ),
            const SizedBox(width: 5),
          ],
          // 文案先让位：窗口窄到放不下时截断的是模型名，不是右侧的折角。
          // 调用方必须给胶囊一个有界宽度（控件行里非 flex 子项拿到的是无界约束，
          // 那时的 `Flexible` 会直接抛断言）。
          //
          // 胶囊按钮按规范走 12.5 档（[AppText.rowSecondary]），不是正文 14：
          // 它是控件文字，与菜单条目同一档，比正文小半号才不会抢过输入内容。
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.of(context).rowSecondary.copyWith(
                fontSize: labelSize,
                color: foreground,
              ),
            ),
          ),
          const SizedBox(width: 2),
          AgentMenuChevron(
            open: open,
            icon: chevron,
            size: chevronSize,
            color: foreground,
          ),
        ],
      ),
    );
  }
}

/// 圆形图标触发器：输入栏「+」用。
///
/// 平时只是一枚极淡的圆底：它贴着输入面板的左下角，太实会跟右侧发送按钮
/// 抢注意力。
class AgentMenuIconTrigger extends StatelessWidget {
  const AgentMenuIconTrigger({
    super.key,
    required this.icon,
    required this.open,
    required this.hovering,
    this.size = 24,
    // 与参考图对齐：十字的视觉跨度约 9px（`Icons.add_rounded` 的笔画
    // 只占字形视框的六成左右，所以 19 才是那个"看起来 9"的值）。
    this.iconSize = 19,
  });

  final IconData icon;
  final bool open;
  final bool hovering;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 与同一行的胶囊走同一个控件灰：整行"入口类"文字/图标只有一个色，
    // 免得「+」比旁边的「请求审批」重一档。
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(
          alpha: open || hovering
              ? AgentMenuStyle.triggerHighlightAlpha
              : AgentMenuStyle.triggerRestAlpha,
        ),
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: iconSize,
        color: AppPalette.of(context).text.control,
      ),
    );
  }
}
