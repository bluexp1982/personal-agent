import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/browser/browser_controller.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import '../../core/ssh/terminal_start_directory.dart';
import 'file_pane_state.dart';
import 'shell_layout_state.dart';

/// 开始页四张能力卡片的 Key。
///
/// 测试之所以按 Key 点而不按文案点：卡片标题会与标签栏文案撞名——「终端」
/// 既是这张卡片，也是打开后那个标签。只靠文字定位会随"标签是否已经存在"
/// 忽多忽少，断言就变成了在考标签栏。
const Key kPanelStartFilesCardKey = Key('panel-start-files');
const Key kPanelStartTerminalCardKey = Key('panel-start-terminal');
const Key kPanelStartBrowserCardKey = Key('panel-start-browser');
const Key kPanelStartGitCardKey = Key('panel-start-git');
const Key kPanelStartMoreCardKey = Key('panel-start-more');

/// 右侧栏的空白页（原来的「开始」页）：面板能力的入口列表。
///
/// 卡片由常量表驱动，以后加浏览器、预览器只追加一项，不改布局。
/// 占位项明确标注「即将支持」，不接假逻辑，避免用户以为功能坏了。
///
/// 一个空白页知道自己是哪张（[tabId]）：点功能时把 id 交给状态层，
/// 由它把**这一页**换成目标标签——用户要的是"在当前页打开"，不是"再多一个标签"。
class PanelStartView extends ConsumerWidget {
  const PanelStartView({super.key, required this.tabId});

  /// 承载本页的空白标签 id。转换后这个 id 就不再存在（标签换了身份）。
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(shellTargetProvider);
    // 项目目录取"最后一个有归属的项目"：录音 / 设置 / 记忆占着中栏时，
    // 右栏里那个项目的文件仍然可浏览，不能让这一页突然说"先选个项目"。
    final projectId = ref.watch(shellProjectMemoProvider);
    final project = _project(ref, target, projectId);
    final canBrowse = projectId.isNotEmpty;

    final actions = <_PanelAction>[
      _PanelAction(
        cardKey: kPanelStartFilesCardKey,
        icon: Icons.folder_copy_outlined,
        title: '项目文件',
        subtitle: !canBrowse
            ? '先在左侧选择一个项目'
            : project == null
            ? '浏览当前项目的文件'
            : '浏览「${project.name}」的文件',
        enabled: canBrowse,
        onTap: () =>
            ref.read(filePaneTabProvider.notifier).openFiles(intoTabId: tabId),
      ),
      _PanelAction(
        cardKey: kPanelStartTerminalCardKey,
        icon: Icons.terminal_outlined,
        title: '终端',
        // 副标题仍写"服务端本机"而不点名项目目录：没有项目、或项目列表还没
        // 加载完时终端落在远端用户的家目录，这里写死一个目录反而自相矛盾。
        // 真正落在哪儿由 [_openTerminal] 按当前项目决定。
        subtitle: '在服务端本机运行命令',
        enabled: true,
        onTap: () => _openTerminal(ref, project),
      ),
      _PanelAction(
        cardKey: kPanelStartBrowserCardKey,
        icon: Icons.language_outlined,
        title: '浏览器',
        subtitle: '浏览本机、服务器或互联网网页',
        enabled: true,
        // 浏览器的语义是"这一页去打开一个网页"：当前这个空白页就地变成浏览器标签，
        // 想再开一页就点标签栏的「+」。新建的浏览器标签是空白页，顺手把焦点交给地址栏。
        onTap: () {
          final id = ref
              .read(filePaneTabProvider.notifier)
              .openNewBrowser(intoTabId: tabId);
          ref.read(browserSessionProvider(id).notifier).requestFocus();
        },
      ),
      _PanelAction(
        cardKey: kPanelStartGitCardKey,
        icon: Icons.call_split_rounded,
        title: 'Git',
        subtitle: !canBrowse ? '先在左侧选择一个项目' : '审查改动、暂存并提交到本地仓库',
        enabled: canBrowse,
        onTap: () =>
            ref.read(filePaneTabProvider.notifier).openGit(intoTabId: tabId),
      ),
      const _PanelAction(
        cardKey: kPanelStartMoreCardKey,
        icon: Icons.grid_view_rounded,
        title: '更多工具',
        subtitle: '后续开放更多面板能力',
      ),
    ];

    // 面板内容在可视区里垂直居中；用 minHeight 撑满而不是外层 Center，
    // 这样内容高于视口时仍能正常滚动，不会被裁掉。
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            // 左（贴分隔线）扣掉栏缝的 8dp，右是窗口边：视觉左右都是同一个内边距。
            padding: const EdgeInsets.fromLTRB(
              kPaneEdgeInset,
              22,
              kPaneContentInset,
              24,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final action in actions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ActionCard(
                          key: action.cardKey,
                          action: action,
                          onUnavailable: () => _explain(context, action),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _explain(BuildContext context, _PanelAction action) {
    final hint = action.comingSoon ? '「${action.title}」即将支持' : action.subtitle;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(hint),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 打开终端，并顺手登记"这次要落在哪个目录"。
  ///
  /// 目录只登记给定价层：真正的 `cd` 由 `SshController` 在 shell 建起来后发送
  /// （dartssh2 的 `shell()` 没有 cwd 参数，后端只是一条 TCP 隧道）。
  /// 终端已经连着时这份意图用不上——`openTerminal` 只会切回那个标签，
  /// 不会往正在跑 vim / top 的 shell 里打字。
  void _openTerminal(WidgetRef ref, Project? project) {
    ref.read(terminalStartDirectoryProvider.notifier).request(project?.path);
    ref.read(filePaneTabProvider.notifier).openTerminal(intoTabId: tabId);
  }

  /// 当前项目：名字给卡片副标题，路径给终端起始目录。
  ///
  /// 会话/任务目标只带 `projectId`，要拿名字与目录得查已缓存的项目列表；
  /// 查不到就退化成 null，让卡片换一句不含项目名的文案，而不是整页空掉。
  Project? _project(WidgetRef ref, ShellTarget? target, String projectId) {
    if (projectId.isEmpty) {
      return null;
    }

    if (target is ProjectTarget) {
      return target.project;
    }

    final items =
        ref.watch(projectsProvider).asData?.value ?? const <Project>[];
    for (final project in items) {
      if (project.id == projectId) {
        return project;
      }
    }
    return null;
  }
}

class _PanelAction {
  const _PanelAction({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.enabled = false,
    this.onTap,
  });

  /// 卡片自己的 Key：测试点它，不点那串可能与标签栏重名的文案。
  final Key cardKey;

  final IconData icon;
  final String title;
  final String subtitle;

  /// 本期可用的入口。未实现的先留占位，等能力落地再打开。
  final bool enabled;
  final VoidCallback? onTap;

  bool get comingSoon => !enabled && onTap == null;
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.action,
    required this.onUnavailable,
  });

  final _PanelAction action;
  final VoidCallback onUnavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = action.enabled
        ? AppPalette.of(context).accent.projectTint
        : scheme.onSurfaceVariant;

    return Opacity(
      opacity: action.enabled ? 1 : 0.72,
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: action.enabled ? action.onTap : onUnavailable,
          hoverColor: tint.withValues(alpha: 0.07),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: action.enabled ? 0.14 : 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(action.icon, size: 17, color: tint),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        action.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: AppFontSize.base,
                          fontWeight: AppWeight.semiBold,
                          color: AppPalette.of(context).text.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: AppFontSize.sm,
                          color: AppPalette.of(context).text.tertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (action.comingSoon) ...<Widget>[
                  const SizedBox(width: 6),
                  const _ComingSoonBadge(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComingSoonBadge extends StatelessWidget {
  const _ComingSoonBadge();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.text.tertiary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        '即将支持',
        style: TextStyle(
          fontSize: AppFontSize.xs,
          fontWeight: AppWeight.semiBold,
          color: palette.text.tertiary,
        ),
      ),
    );
  }
}
