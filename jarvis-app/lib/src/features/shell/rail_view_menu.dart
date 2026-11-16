import 'package:flutter/material.dart';

import '../../core/ui/agent_menu.dart';
import 'pane_controls.dart';
import 'rail_section_icons.dart';
import 'shell_layout_state.dart';

/// 左栏「视图选项」入口的 Key。
const Key kRailViewOptionsKey = Key('shell-rail-view-options');

/// 视图选项浮层的宽度。
///
/// 定值而不是跟着触发器走：触发器只有 24dp，跟着它会窄到放不下
/// 「全部对话（显示已归档）」这种长文案。参考图也是小图标、宽菜单。
const double kRailViewMenuWidth = 232;

/// 浮层里的一项：只有展示信息，不含业务语义。
@immutable
class RailViewMenuItem {
  const RailViewMenuItem({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;
  final IconData icon;
}

/// 浮层里的一组：标题 + 若干互斥选项。
@immutable
class RailViewMenuGroup {
  const RailViewMenuGroup({required this.title, required this.items});

  final String title;
  final List<RailViewMenuItem> items;
}

/// 「视图选项」的三组选项，顺序即展示顺序。
///
/// 全部是占位：点击只切换本组勾选，不改变列表的实际分组/排序/筛选。
/// 接上真实能力后，把选中回调从这里传出去即可，渲染部分不用动。
const List<RailViewMenuGroup> kRailViewMenuGroups = <RailViewMenuGroup>[
  RailViewMenuGroup(
    title: '分组方式',
    items: <RailViewMenuItem>[
      RailViewMenuItem(
        id: 'project',
        label: '按项目',
        icon: Icons.folder_outlined,
      ),
      RailViewMenuItem(
        id: 'project-tree',
        label: '按项目树',
        icon: Icons.account_tree_outlined,
      ),
      RailViewMenuItem(
        id: 'single-list',
        label: '单列表',
        icon: Icons.format_list_bulleted_rounded,
      ),
    ],
  ),
  RailViewMenuGroup(
    title: '排序方式',
    items: <RailViewMenuItem>[
      RailViewMenuItem(
        id: 'manual',
        label: '手动排序',
        icon: Icons.swap_vert_rounded,
      ),
      RailViewMenuItem(
        id: 'recent',
        label: '最近更新',
        icon: Icons.schedule_rounded,
      ),
    ],
  ),
  RailViewMenuGroup(
    title: '筛选会话',
    items: <RailViewMenuItem>[
      RailViewMenuItem(
        id: 'hide-archived',
        label: '隐藏已归档',
        icon: Icons.archive_outlined,
      ),
      RailViewMenuItem(
        id: 'all',
        label: '全部对话（显示已归档）',
        icon: Icons.inbox_outlined,
      ),
      RailViewMenuItem(
        id: 'archived-only',
        label: '仅显示已归档',
        icon: Icons.inventory_2_outlined,
      ),
    ],
  ),
];

/// 每组默认勾选的项，与参考图一致。
const String kRailViewDefaultGrouping = 'project';
const String kRailViewDefaultSorting = 'recent';
const String kRailViewDefaultFilter = 'hide-archived';

/// 「项目」标题行右端的视图选项入口。
///
/// 三个选择存在按钮自己的 `State` 里而不是 provider：占位期它不影响列表，
/// 进全局状态只会给一个假功能引入无谓的订阅与重建。
/// 只要侧栏不重建整棵子树，关掉再打开就还是上次的勾选。
class RailViewOptionsButton extends StatefulWidget {
  const RailViewOptionsButton({super.key, this.iconSize = kRailItemIconSize});

  final double iconSize;

  @override
  State<RailViewOptionsButton> createState() => _RailViewOptionsButtonState();
}

class _RailViewOptionsButtonState extends State<RailViewOptionsButton> {
  String _grouping = kRailViewDefaultGrouping;
  String _sorting = kRailViewDefaultSorting;
  String _filter = kRailViewDefaultFilter;

  /// 当前组勾选的 id。
  String _selectedOf(String title) => switch (title) {
    '分组方式' => _grouping,
    '排序方式' => _sorting,
    _ => _filter,
  };

  void _select(String title, String id) {
    setState(() {
      switch (title) {
        case '分组方式':
          _grouping = id;
        case '排序方式':
          _sorting = id;
        default:
          _filter = id;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AgentMenu<String>(
      width: kRailViewMenuWidth,
      // 与输入栏「+」菜单同一对齐：面板左上角落在触发器左下角，
      // 左边缘贴着触发器左边缘。`bottomEnd` 会把面板整体甩到触发器右侧
      // （它只把面板左上角放在触发器右下角），看起来像和图标错开一截。
      alignment: AlignmentDirectional.bottomStart,
      // 触发器是自带 onPressed 的图标按钮：点击交给它，组件只负责开合状态。
      triggerHandlesTap: false,
      groups: <AgentMenuGroup<String>>[
        for (var i = 0; i < kRailViewMenuGroups.length; i++)
          AgentMenuGroup<String>(
            title: kRailViewMenuGroups[i].title,
            // 组之间用分组线隔开：三组各自互斥，是三种不同的设置。
            dividerBefore: i > 0,
            items: <AgentMenuItem<String>>[
              for (final item in kRailViewMenuGroups[i].items)
                AgentMenuItem<String>(
                  key: Key('rail-view-item-${item.id}'),
                  value: item.id,
                  label: item.label,
                  icon: item.icon,
                  selected:
                      _selectedOf(kRailViewMenuGroups[i].title) == item.id,
                  onSelected: (id) => _select(kRailViewMenuGroups[i].title, id),
                ),
            ],
          ),
      ],
      onSelected: (_) {},
      builder: (context, controller, open, hovering) => RailSectionIconButton(
        key: kRailViewOptionsKey,
        iconBuilder: (color) => RailSectionGlyph(
          kind: RailSectionGlyphKind.viewOptions,
          color: color,
          size: widget.iconSize,
        ),
        tooltip: '视图选项',
        active: open,
        iconSize: widget.iconSize,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
