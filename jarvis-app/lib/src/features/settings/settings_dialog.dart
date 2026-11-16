import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/session.dart';
import '../../core/ui/app_dialog.dart';
import '../shell/shell_dividers.dart';
import 'settings_sections.dart';

/// 宽屏设置弹窗的根 Key（测试用来断言"设置现在是浮层"）。
const Key kSettingsDialogKey = Key('settings-dialog');

/// 浮层本体（尺寸由它承载，`Dialog` 外层铺满整屏，量不出实际大小）。
const Key kSettingsDialogPanelKey = Key('settings-dialog-panel');

/// 标题行右端的关闭按钮。
const Key kSettingsDialogCloseKey = Key('settings-dialog-close');

/// 左栏某一栏的入口行。
Key settingsSectionItemKey(SettingsSection section) =>
    Key('settings-section-item-${section.name}');

/// 某一栏内容区的 Key。
///
/// 右栏是懒构建的堆叠：只有访问过的栏才在树上，测试不能靠
/// `find.byType(SettingsSectionView)` 的数量判断"当前是哪一栏"。
Key settingsSectionViewKey(SettingsSection section) =>
    Key('settings-section-view-${section.name}');

/// 弹出宽屏设置。
///
/// 设置不再是中栏的一页：它是覆盖在应用之上的一层浮层，关掉之后聊天、项目、
/// 终端都还在原处。
///
/// 弹窗里没有跳往其它页面的入口：记忆 / 无限画布 / 录音笔记各有自己的左栏
/// 与底部导航入口，浮层只负责「调这台机器自己的设置」。
Future<void> showSettingsDialog(
  BuildContext context, {
  required SessionState session,
}) {
  // 遮罩深浅与弹窗底色都由 `showAppDialog` / `AppDialog` 统一，这里不再传。
  return showAppDialog<void>(
    context,
    builder: (_) => SettingsDialog(session: session),
  );
}

/// 左右分栏的设置浮层：左侧内栏标题、右侧当前栏内容。
///
/// 尺寸在打开那一刻按视口算好（`min(880, 宽 - 48)` × `min(640, 高 - 80)`）：
/// 交给 `Dialog` 的 `insetPadding` 与内部 `maxHeight` 互相挤压时，小窗口下
/// 会出现"内容被裁掉一截却还能滚"的怪状态。
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.session});

  final SessionState session;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  /// 当前栏。每次重开回到「连接与设备」：设置不是浏览型页面，
  /// 上次停在哪一栏对下一次打开没有参考价值。
  SettingsSection _selected = SettingsSection.connection;

  /// 访问过的栏。只增不减：模型 / 技能包列表不该因为切走再回来重拉一次，
  /// 各栏的滚动位置也要留着（写法同 `NarrowTabs._built`）。
  final Set<SettingsSection> _built = <SettingsSection>{
    SettingsSection.connection,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final width = math.min(880.0, math.max(280.0, viewport.width - 48));
    final height = math.min(640.0, math.max(320.0, viewport.height - 80));

    return AppDialog(
      dialogKey: kSettingsDialogKey,
      panelKey: kSettingsDialogPanelKey,
      closeKey: kSettingsDialogCloseKey,
      title: '设置',
      // 尺寸自己算好，不再让 Dialog 的默认 48/80 外边距与它打架。
      insetPadding: EdgeInsets.zero,
      width: width,
      height: height,
      // 左右分栏各自滚动：这层不再套整块滚动，否则两个 ListView 会互相抢视口。
      scrollable: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: 200, child: _sectionNav(context)),
          Container(
            width: 1,
            margin: const EdgeInsets.symmetric(vertical: 12),
            color: shellDividerColor(scheme),
          ),
          Expanded(child: _sectionBody(context)),
        ],
      ),
    );
  }

  Widget _sectionNav(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      children: <Widget>[
        for (final section in SettingsSection.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: InkWell(
              key: settingsSectionItemKey(section),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              hoverColor: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
              onTap: () {
                if (section == _selected) {
                  return;
                }
                setState(() {
                  _selected = section;
                  _built.add(section);
                });
              },
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  // 「悬停重、选中淡」是左栏行的既定口径，此处照抄同一套强度。
                  color: section == _selected
                      ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                      : null,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      section.icon,
                      size: 16,
                      color: section == _selected
                          ? palette.text.primary
                          : palette.text.secondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        section.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.base,
                          height: AppLineHeight.tight,
                          fontWeight: AppWeight.regular,
                          color: palette.text.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _sectionBody(BuildContext context) {
    // 用 `Stack` + `Visibility(maintainState:)` 而不是 `IndexedStack`：
    // 后者会把未选中的分支留在布局与语义树里（只是不画），读屏与测试都能
    // 摸到别的栏的内容；`Offstage` 保留 State 与滚动位置，但真的"不在这一屏"。
    return Stack(
      children: <Widget>[
        for (final section in SettingsSection.values)
          if (_built.contains(section))
            Positioned.fill(
              child: Visibility(
                visible: section == _selected,
                maintainState: true,
                maintainAnimation: true,
                child: SettingsSectionView(
                  key: settingsSectionViewKey(section),
                  session: widget.session,
                  section: section,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                ),
              ),
            ),
      ],
    );
  }
}
