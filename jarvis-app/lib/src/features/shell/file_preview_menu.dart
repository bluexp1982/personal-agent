import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ui/agent_menu.dart';

/// 面板本身。测试按它断言"弹出来的是我们的菜单，不是系统工具条"。
const Key kPreviewContextMenuKey = Key('shell-preview-context-menu');

/// 菜单里的一行。按类型生成：同一个菜单里同一类型不会出现两次。
Key previewMenuButtonKey(ContextMenuButtonType type) =>
    ValueKey<String>('shell-preview-context-menu-${type.name}');

/// 预览正文的右键菜单。
///
/// 由 `SelectionArea.contextMenuBuilder` 返回：外层 `ContextMenuController`
/// 已经托管了一个 OverlayEntry，并把坐标系抵消成"根 Overlay 的全局坐标"
/// （见 Flutter 内部的 `_SelectionToolbarWrapper` 与它包着的
/// `CompositedTransformFollower`），所以这里只需要按
/// `contextMenuAnchors.primaryAnchor` 摆面板。
///
/// 为什么不包一层 `AgentMenu`：`MenuAnchor` 的"点外部关闭"只收自己，
/// 不通知外层 Overlay；残留的 OverlayEntry 会让下一次右键只 markNeedsBuild，
/// 菜单再也弹不出来。面板自己画在现有 Overlay 里，关闭统一走
/// [SelectableRegionState.hideToolbar]。
///
/// 菜单内容完全跟随当前平台的 `contextMenuButtonItems`：有选区才有「复制」，
/// 桌面复制后自动收菜单、移动端全选后按系统规则重弹手柄，这些差异不在这里
/// 重新判断一遍。条目之间不插分组线——它们本来就是同一组动作。
class FilePreviewContextMenu extends StatelessWidget {
  const FilePreviewContextMenu({super.key, required this.state});

  /// 选区状态：提供锚点、平台按钮列表与收起菜单的入口。
  final SelectableRegionState state;

  @override
  Widget build(BuildContext context) {
    // `contextMenuAnchors` 读一次会清空右键落点（Flutter 的默认工具条也这样），
    // 必须只取一次，否则同一帧里第二次读会退回成"按选区算"。
    final anchor = state.contextMenuAnchors.primaryAnchor;
    final items = _buildItems();
    if (items.isEmpty) {
      // 没有可用项：不画一个空面板。
      return const SizedBox.shrink();
    }

    return TapRegion(
      // 与 `SelectionArea` 自带的 TapRegion 同组：点菜单内部不算"点外部"，
      // 只有点在预览与菜单之外才收起。
      groupId: SelectableRegion,
      onTapOutside: (_) => state.hideToolbar(),
      child: CustomSingleChildLayout(
        delegate: _PreviewMenuLayout(anchor: anchor),
        child: AgentMenuPanel<ContextMenuButtonItem>(
          key: kPreviewContextMenuKey,
          width: AgentMenuStyle.panelMinWidth,
          groups: <AgentMenuGroup<ContextMenuButtonItem>>[
            AgentMenuGroup<ContextMenuButtonItem>(items: items),
          ],
          // 平台回调里已经处理了"复制后清选区 / 收起工具条 / 移动端重弹手柄"。
          onSelected: (item) => item.onPressed?.call(),
        ),
      ),
    );
  }

  List<AgentMenuItem<ContextMenuButtonItem>> _buildItems() {
    final items = <AgentMenuItem<ContextMenuButtonItem>>[];
    for (final item in state.contextMenuButtonItems) {
      final descriptor = _descriptorOf(item);
      if (descriptor == null) {
        continue;
      }
      items.add(
        AgentMenuItem<ContextMenuButtonItem>(
          key: previewMenuButtonKey(item.type),
          value: item,
          icon: descriptor.icon,
          label: descriptor.label,
        ),
      );
    }
    return items;
  }
}

/// 平台按钮 → 中文文案与图标。
///
/// 已知类型统一翻成中文（默认工具条在未配置中文本地化时是英文的
/// Copy / Select All）；引擎追加的查词、翻译等动作没有对应类型，
/// 沿用它们自带的 `label`，没有 label 的就不显示。
({String label, IconData? icon})? _descriptorOf(ContextMenuButtonItem item) {
  switch (item.type) {
    case ContextMenuButtonType.copy:
      return (label: '复制', icon: Icons.content_copy_rounded);
    case ContextMenuButtonType.selectAll:
      return (label: '全选', icon: Icons.select_all_rounded);
    case ContextMenuButtonType.share:
      return (label: '分享', icon: Icons.ios_share_rounded);
    case ContextMenuButtonType.cut:
      return (label: '剪切', icon: Icons.content_cut_rounded);
    case ContextMenuButtonType.paste:
      return (label: '粘贴', icon: Icons.content_paste_rounded);
    case ContextMenuButtonType.delete:
      return (label: '删除', icon: Icons.delete_outline_rounded);
    case ContextMenuButtonType.lookUp:
      return (label: '查询', icon: Icons.search_rounded);
    case ContextMenuButtonType.searchWeb:
      return (label: '在网页中搜索', icon: Icons.travel_explore_rounded);
    case ContextMenuButtonType.liveTextInput:
    case ContextMenuButtonType.custom:
      final label = item.label;
      return label == null ? null : (label: label, icon: null);
  }
}

/// 把面板左上角放在右键落点，靠近窗口右/下边缘时夹回视口。
///
/// 与 `AgentMenu(alignmentOffset: Offset.zero)` 的口径一致：菜单从落点向右下长，
/// 不做额外的"向下 6dp"偏移——那种偏移是给按钮触发器用的，右键菜单贴着手
/// 的位置才自然。
class _PreviewMenuLayout extends SingleChildLayoutDelegate {
  const _PreviewMenuLayout({required this.anchor});

  /// 全局坐标（根 Overlay 的坐标系）。
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final available = constraints.maxHeight.isFinite
        ? constraints.maxHeight
        : AgentMenuStyle.panelMaxHeight;
    return BoxConstraints(
      maxWidth: AgentMenuStyle.panelMinWidth,
      maxHeight: math.min(AgentMenuStyle.panelMaxHeight, available),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = math.max(0.0, size.width - childSize.width);
    final maxY = math.max(0.0, size.height - childSize.height);
    return Offset(
      anchor.dx.clamp(0.0, maxX).toDouble(),
      anchor.dy.clamp(0.0, maxY).toDouble(),
    );
  }

  @override
  bool shouldRelayout(_PreviewMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}
