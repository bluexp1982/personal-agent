import 'package:flutter/material.dart';

import '../../core/ui/agent_menu.dart';
import 'file_pane_state.dart';

/// 标签右键菜单里的四个动作。
///
/// 只描述"要关哪一段"，不关心终端要不要断连、活动标签回落到谁——
/// 那些属于状态层与调用方，菜单本身保持成一张纯展示的清单。
enum PanelTabMenuAction { close, closeOthers, closeLeft, closeRight }

/// 菜单项的定位 Key。
///
/// 按文案断言太脆（改一个字就全线失配），也可能和标签上的同名文字撞车，
/// 所以每个动作给一个稳定 Key。
const Key kPanelTabMenuCloseKey = Key('shell-panel-tab-menu-close');
const Key kPanelTabMenuCloseOthersKey = Key(
  'shell-panel-tab-menu-close-others',
);
const Key kPanelTabMenuCloseLeftKey = Key('shell-panel-tab-menu-close-left');
const Key kPanelTabMenuCloseRightKey = Key('shell-panel-tab-menu-close-right');

/// 标签栏「更多」按钮的 Key。
const Key kPanelMoreMenuKey = Key('shell-panel-more-menu');

/// 「更多」菜单里某个标签项的 Key（一个标签一个）。
///
/// 和标签栏上的 `panelTabKey` 分开：同一个标签在两处各有一份可点区域，
/// 测试要能精确点到"菜单里的那一行"。
Key panelMoreTabKey(String id) => Key('shell-panel-more-menu-tab-$id');

/// 「更多」菜单底部两个批量关闭项的 Key。
const Key kPanelTabMoreCloseOthersKey = Key(
  'shell-panel-more-menu-close-others',
);
const Key kPanelTabMoreCloseAllKey = Key('shell-panel-more-menu-close-all');

/// 「更多」菜单底部的两个批量关闭动作。
///
/// 与右键菜单的 [PanelTabMenuAction] 分开而不是复用：那边的四项都是
/// "按被右键的那个标签算一段"，锚点来自点击落点；这边只有两项，锚点是
/// 当前标签与整栏，两者的判断依据不同，混在一张枚举里会让调用方猜锚点。
enum PanelTabMoreAction { closeOthers, closeAll }

/// 「更多」菜单里可以被选中的东西。
///
/// 用 sealed 而不是一个可空的 `String` + 另一张表：标签项要带标签 id、
/// 动作项要带枚举，两种语义挤进同一个字段只能靠约定；分成两个子类型后
/// `switch` 是穷尽的，以后加动作不会漏分支。
sealed class PanelTabMoreSelection {
  const PanelTabMoreSelection();
}

/// 切到某个标签。
final class PanelTabMoreSwitch extends PanelTabMoreSelection {
  const PanelTabMoreSwitch(this.id);

  final String id;
}

/// 执行一个批量关闭动作。
final class PanelTabMoreClose extends PanelTabMoreSelection {
  const PanelTabMoreClose(this.action);

  final PanelTabMoreAction action;
}

/// 按被右键的标签算出四项菜单。
///
/// 可用性直接由"能关掉几个"决定：`otherTabs` / `tabsBefore` / `tabsAfter`
/// 不再豁免任何标签，所以只剩一个标签时三个批量项自然置灰，
/// 不需要在这里另写一套判断。
List<AgentMenuItem<PanelTabMenuAction>> tabMenuItems({
  required FilePaneTabState state,
  required PanelTabRef anchor,
}) {
  return <AgentMenuItem<PanelTabMenuAction>>[
    AgentMenuItem<PanelTabMenuAction>(
      key: kPanelTabMenuCloseKey,
      value: PanelTabMenuAction.close,
      icon: Icons.close_rounded,
      label: '关闭',
      // 空白页也能关：关掉最后一个标签时右栏会自己收起，
      // 所以"关闭"不存在"点了却什么都不会发生"的情况。
      enabled: true,
    ),
    AgentMenuItem<PanelTabMenuAction>(
      key: kPanelTabMenuCloseOthersKey,
      value: PanelTabMenuAction.closeOthers,
      icon: Icons.clear_all_rounded,
      label: '关闭其他标签页',
      enabled: state.otherTabs(anchor).isNotEmpty,
    ),
    AgentMenuItem<PanelTabMenuAction>(
      key: kPanelTabMenuCloseLeftKey,
      value: PanelTabMenuAction.closeLeft,
      icon: Icons.keyboard_double_arrow_left_rounded,
      label: '关闭左侧标签页',
      enabled: state.tabsBefore(anchor).isNotEmpty,
    ),
    AgentMenuItem<PanelTabMenuAction>(
      key: kPanelTabMenuCloseRightKey,
      value: PanelTabMenuAction.closeRight,
      icon: Icons.keyboard_double_arrow_right_rounded,
      label: '关闭右侧标签页',
      enabled: state.tabsAfter(anchor).isNotEmpty,
    ),
  ];
}
