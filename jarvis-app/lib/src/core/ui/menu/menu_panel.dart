import 'package:flutter/material.dart';

import 'menu_model.dart';
import 'menu_parts.dart';

/// 把分组数据摊平成菜单浮层要的 widget 列表。
///
/// [AgentMenu]（触发器 + `MenuAnchor`）与 [AgentMenuPanel]（没有触发器的浮层，
/// 比如 `SelectionArea.contextMenuBuilder` 返回的预览右键菜单）共用这一份实现：
/// 分组线、分组标题、四种行的选择规则只写一遍，两处外观才不会各自漂移。
List<Widget> buildAgentMenuRows<T>({
  required List<AgentMenuGroup<T>> groups,
  required double panelWidth,
  required ValueChanged<T> onSelected,
}) {
  final contentWidth = AgentMenuStyle.contentWidthOf(panelWidth);
  final rows = <Widget>[];
  var first = true;

  for (final group in groups) {
    if (group.items.isEmpty) {
      continue;
    }
    if (!first && group.dividerBefore) {
      rows.add(const AgentMenuDivider());
    }
    if (group.title != null) {
      rows.add(AgentMenuSectionHeader(title: group.title!));
    }
    for (final item in group.items) {
      if (!first && item.dividerBefore) {
        rows.add(const AgentMenuDivider());
      }
      rows.add(_buildRow(item, panelWidth, contentWidth, onSelected));
      first = false;
    }
  }
  return rows;
}

Widget _buildRow<T>(
  AgentMenuItem<T> item,
  double panelWidth,
  double contentWidth,
  ValueChanged<T> onSelected,
) {
  final onPressed = _pressHandler(item, onSelected);

  // 有二级列表 → 「标题 + 当前值 + ›」。二级浮层自己再摊平一次。
  if (item.submenu != null) {
    final submenuWidth = item.submenuWidth ?? panelWidth;
    return AgentMenuSubmenuRow(
      buttonKey: item.key,
      label: item.label,
      value: item.submenuValue ?? '',
      width: AgentMenuStyle.submenuRowWidthOf(panelWidth),
      menuWidth: submenuWidth,
      menuChildren: buildAgentMenuRows(
        groups: item.submenu!,
        panelWidth: submenuWidth,
        onSelected: onSelected,
      ),
    );
  }

  // 有两行内容 → 富文本行（模式下拉）。
  if (item.subtitle != null) {
    return AgentMenuRichRow(
      buttonKey: item.key,
      label: item.label,
      subtitle: item.subtitle,
      width: contentWidth,
      selected: item.selected,
      enabled: item.enabled,
      onPressed: onPressed,
      leading: item.leading,
      labelSize: item.labelSize ?? AgentMenuStyle.optionLabelSize,
      labelWeight: item.labelWeight,
      selectedColor: item.selectedColor,
    );
  }

  // 有别名或行尾说明 → 命令行（「+」菜单）。
  if (item.alias != null || item.description != null) {
    return AgentMenuCommandRow(
      buttonKey: item.key,
      item: item,
      width: contentWidth,
      onPressed: onPressed,
      // 命令行也要能表达"键盘停在这一行"：输入栏 `@` 候选没有
      // `MenuAnchor` 的方向键遍历，高亮由调用方通过 `selected` 驱动。
      highlighted: item.selected,
    );
  }

  // 其余 → 选项行（单选、右键动作）。
  return AgentMenuOptionRow(
    buttonKey: item.key,
    label: item.label,
    width: contentWidth,
    selected: item.selected,
    enabled: item.enabled,
    onPressed: onPressed,
    icon: item.icon,
    leading: item.leading,
    badge: item.badge,
    labelSize: item.labelSize ?? AgentMenuStyle.optionLabelSize,
    labelWeight: item.labelWeight,
    selectedColor: item.selectedColor,
  );
}

/// 一行的点击回调。
///
/// 收菜单不用我们管：`MenuItemButton` 会先调 `MenuController.close()`（若有），
/// 再把 `onPressed` 推到帧末尾执行——那时这条子树可能已经失活，
/// 所以这里只捕获回调与值，不再碰 `BuildContext`。
VoidCallback? _pressHandler<T>(
  AgentMenuItem<T> item,
  ValueChanged<T> onSelected,
) {
  if (!item.enabled) {
    return null;
  }
  final value = item.value;
  if (value == null) {
    // 没有回传值的项（占位期的空动作）：点击仍然收起菜单。
    return () {};
  }
  final callback = item.onSelected ?? onSelected;
  return () => callback(value);
}

/// 没有触发器的菜单面板。
///
/// 用于「浮层本来就已经在某个 Overlay 里」的场景——`SelectionArea` 的
/// `contextMenuBuilder` 就是典型：外层由 `ContextMenuController` 托管一个
/// OverlayEntry，再套一层 `MenuAnchor` 会在点外部关闭时只收自己、留下一个
/// 看不见的外层 Overlay，下一次右键就弹不出来了。
///
/// 外观（背景、表面染色的关掉、阴影、elevation、圆角描边、内边距）全部从
/// [AgentMenuStyle.panelStyleOf] 解析，与 `MenuAnchor` 面板同源；行由
/// [buildAgentMenuRows] 生成，与 [AgentMenu] 同一套。
///
/// 面板自己不接管焦点：宿主（比如预览正文的 `SelectionArea`）通常需要保持焦点
/// 才能保住选区，抢过来会把选区清空。因此这里没有方向键遍历；Esc、点外部收起
/// 由宿主负责。
class AgentMenuPanel<T> extends StatelessWidget {
  const AgentMenuPanel({
    super.key,
    required this.width,
    required this.groups,
    required this.onSelected,
    this.maxHeight = AgentMenuStyle.panelMaxHeight,
  });

  /// 面板宽度。与 [AgentMenu.width] 同口径：定值，不跟内容伸缩。
  final double width;

  final List<AgentMenuGroup<T>> groups;

  final ValueChanged<T> onSelected;

  /// 面板最大高度：超出后内部滚动。
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    const states = <WidgetState>{};
    final scheme = Theme.of(context).colorScheme;
    final style = AgentMenuStyle.panelStyleOf(context);
    // 形状必须兜底：`MenuStyle.shape` 是可空的，缺省时按面板圆角来，
    // 否则 Material 会退回直角，和全站菜单不是一套轮廓。
    final shape =
        style.shape?.resolve(states) ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AgentMenuStyle.panelRadius),
        );

    return Material(
      color: style.backgroundColor?.resolve(states) ?? scheme.surface,
      surfaceTintColor:
          style.surfaceTintColor?.resolve(states) ?? Colors.transparent,
      shadowColor: style.shadowColor?.resolve(states) ?? scheme.shadow,
      elevation: style.elevation?.resolve(states) ?? 0,
      shape: shape,
      // 圆角 + 描边 + 可滚动内容：不裁的话滚动时条目会盖到圆角与描边上。
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            padding:
                style.padding?.resolve(states) ??
                const EdgeInsets.all(AgentMenuStyle.panelPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: buildAgentMenuRows(
                groups: groups,
                panelWidth: width,
                onSelected: onSelected,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
