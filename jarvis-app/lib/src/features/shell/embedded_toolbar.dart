import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/window_chrome.dart';
import 'pane_controls.dart';
import 'shell_dividers.dart';
import 'shell_layout_state.dart';

/// 本行自身的左内边距。
///
/// 与 [MacTrafficLightInset] 的占位共用：那一块要扣掉它，两者相加才等于
/// `paneHeaderLeadingLine`，左栏展开 / 收起时开合按钮才落在同一根竖线上。
const double _toolbarLeadingInset = 4;

/// 嵌在中栏里的工具行：左侧标题（可带一个退出管理用的图标）+ 右侧动作。
///
/// 项目详情已经有头图与 Tab，再叠一层 AppBar 会有两条标题栏；
/// 但「管理 / 刷新」又必须够得着，于是收敛成这一条细工具行。
///
/// 三栏布局把这行也当成中栏的「栏头」：最左是左栏展开按钮（仅在左栏收起时），
/// 最右是右栏开关。空白处可以拖动窗口。
class EmbeddedToolbar extends ConsumerWidget {
  const EmbeddedToolbar({
    super.key,
    required this.title,
    required this.actions,
    this.leading,
    this.subtitle,
    this.emphasizeTitle = false,
    this.showPaneToggles = true,
  });

  final String title;

  /// 标题右侧的次要信息（项目路径）。单行省略，不参与主标题的层级。
  final String? subtitle;

  /// 主标题是否需要强调（例如项目名），默认是普通工具行标题。
  final bool emphasizeTitle;
  final List<Widget> actions;
  final Widget? leading;

  /// 项目详情页由自己的头图承载开合按钮时，内部 Tab 的工具行传 false，
  /// 避免同一屏出现两套相同的按钮。
  final bool showPaneToggles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 宽屏三栏的栏头横线由骨架层的 `ShellDividers` 画：它要跨过 8dp 拖动条
    // 才连得上右栏标签栏那条线，栏自己画只能画到中栏右边界，拐角必断。
    // 窄屏没有那一层，仍由这里画。
    final shellDividers = ShellDividerScope.isActive(context);

    return Container(
      // 与右栏标签栏、左栏栏头同高（见 `kPaneHeaderHeight` 的推导），
      // 三栏按钮因此落在同一条水平线上；macOS 的红绿灯也由原生侧下移到
      // 这条中线上（`MainFlutterWindow.alignTrafficLights`）。本行比原生
      // 标题条高出来的部分只用于拖动。
      height: kPaneHeaderHeight,
      // 不画 border 时补上等高的底部内边距：内容区高度不变，栏头按钮仍与
      // 左右两栏的图标落在同一条水平线上。
      padding: EdgeInsets.fromLTRB(
        _toolbarLeadingInset,
        0,
        6,
        shellDividers ? kPaneHeaderBorderWidth : 0,
      ),
      decoration: shellDividers
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: shellDividerColor(theme.colorScheme)),
              ),
            ),
      child: Row(
        children: <Widget>[
          if (showPaneToggles) ...<Widget>[
            const MacTrafficLightInset(leadingInset: _toolbarLeadingInset),
            const RailToggleButton(onlyWhenCollapsed: true),
            // 后退 / 前进跟着开合走：左栏收起后它们从中栏栏头接管，
            // 与左栏那一份互斥（见 `HistoryNavButtons`）。
            const HistoryNavButtons(onlyWhenCollapsed: true),
            // 新建会话跟在导航后面：左栏收起后它是侧栏那枚整行按钮的唯一替代入口。
            const NewConversationButton(),
          ],
          ?leading,
          Expanded(
            child: WindowDragArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Flexible(
                      flex: 2,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: emphasizeTitle
                            ? theme.textTheme.titleSmall?.copyWith(
                                fontSize: AppFontSize.md,
                                fontWeight: AppWeight.semiBold,
                                color: AppPalette.of(context).text.primary,
                              )
                            : theme.textTheme.labelLarge?.copyWith(
                                fontSize: AppFontSize.base,
                                color: AppPalette.of(context).text.secondary,
                              ),
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.of(context).mono(
                            size: AppFontSize.xs,
                            height: AppLineHeight.tight,
                            color: AppPalette.of(context).text.tertiary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          ...actions,
          if (showPaneToggles) const FilePaneToggleButton(),
        ],
      ),
    );
  }
}
