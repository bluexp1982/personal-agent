import 'package:flutter/material.dart';

import '../../core/memory/memory_models.dart';
import '../../core/ui/agent_menu.dart';

/// 记忆页「⋯」菜单里可以被选中的东西。
///
/// 动作与子页面跳转、清空归档的类别收窄挤在一张菜单里，用 sealed 分开：
/// `switch` 穷尽，以后加项不会漏分支（与 `panel_tab_menu.dart` 同一约定）。
sealed class MemoryMenuSelection {
  const MemoryMenuSelection();
}

/// 手动整理一次（忙碌时菜单项置灰，不会选到）。
final class MemoryMenuOrganize extends MemoryMenuSelection {
  const MemoryMenuOrganize();
}

/// 跳候选确认页。
final class MemoryMenuCandidates extends MemoryMenuSelection {
  const MemoryMenuCandidates();
}

/// 跳项目记忆导出页。
final class MemoryMenuExport extends MemoryMenuSelection {
  const MemoryMenuExport();
}

/// 清空归档。`kind == null` 是「全部」。
final class MemoryMenuPurgeArchived extends MemoryMenuSelection {
  const MemoryMenuPurgeArchived(this.kind);

  final MemoryKind? kind;
}

/// 触发器按钮的 Key：测试要点开菜单，按图标找会和设置图标撞车。
const Key kMemoryMenuKey = Key('memory-page-menu');

/// 「清空归档」子菜单项的 Key。确认弹框的断言按文案即可（全页唯一）。
Key memoryPurgeMenuKey(MemoryKind? kind) =>
    Key('memory-page-menu-purge-${kind?.wire ?? 'all'}');

/// 记忆页标题栏的「⋯」菜单。
///
/// 有子页面的项按需求在文字上加「…」；「清空归档」是二级子菜单，
/// 行尾的「›」由组件自己画。
List<AgentMenuGroup<MemoryMenuSelection>> memoryMenuGroups({
  required bool organizing,
  required int candidateCount,
  required int archivedCount,
}) {
  return <AgentMenuGroup<MemoryMenuSelection>>[
    AgentMenuGroup<MemoryMenuSelection>(
      items: <AgentMenuItem<MemoryMenuSelection>>[
        AgentMenuItem<MemoryMenuSelection>(
          value: const MemoryMenuOrganize(),
          label: organizing ? '整理中' : '整理',
          icon: Icons.auto_fix_high_outlined,
          enabled: !organizing,
        ),
        AgentMenuItem<MemoryMenuSelection>(
          value: const MemoryMenuCandidates(),
          label: '候选…',
          icon: Icons.playlist_add_check_outlined,
          badge: candidateCount > 0 ? '$candidateCount' : null,
        ),
        AgentMenuItem<MemoryMenuSelection>(
          value: const MemoryMenuExport(),
          label: '导出…',
          icon: Icons.ios_share_outlined,
        ),
        // 没有归档可清时退化成置灰的普通行：子菜单行（SubmenuButton）不支持
        // 置灰，给它挂 enabled 没用。
        if (archivedCount > 0)
          AgentMenuItem<MemoryMenuSelection>(
            label: '清空归档',
            icon: Icons.delete_sweep_outlined,
            dividerBefore: true,
            submenu: <AgentMenuGroup<MemoryMenuSelection>>[
              AgentMenuGroup<MemoryMenuSelection>(
                items: <AgentMenuItem<MemoryMenuSelection>>[
                  AgentMenuItem<MemoryMenuSelection>(
                    key: memoryPurgeMenuKey(null),
                    value: const MemoryMenuPurgeArchived(null),
                    label: '全部',
                  ),
                  for (final kind in MemoryKind.values)
                    AgentMenuItem<MemoryMenuSelection>(
                      key: memoryPurgeMenuKey(kind),
                      value: MemoryMenuPurgeArchived(kind),
                      label: kind.label,
                    ),
                ],
              ),
            ],
          )
        else
          const AgentMenuItem<MemoryMenuSelection>(
            label: '清空归档',
            icon: Icons.delete_sweep_outlined,
            dividerBefore: true,
            enabled: false,
          ),
      ],
    ),
  ];
}

/// 「清空归档」的确认框。返回 true 表示用户确认执行。
///
/// 文案必须写清范围与后果：用户要分清「清归档」和「删记忆」是两回事。
Future<bool> confirmPurgeArchived(BuildContext context, MemoryKind? kind) async {
  final scope = kind == null ? '全部已归档的记忆' : '已归档的「${kind.label}」记忆';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('清空$scope？'),
      content: const Text('归档是"不再作数的历史存档"，清空不影响生效中的记忆；此操作不可撤销。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
