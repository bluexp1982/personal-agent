import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/git_models.dart';
import '../../core/git_providers.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/file_pane_state.dart';
import '../shell/shell_layout_state.dart';
import 'git_change_list.dart';
import 'git_commit_box.dart';
import 'git_diff_view.dart';
import 'git_history_view.dart';

/// 右栏 Git 面板：分支栏 + 「变更 / 历史」+ 底部提交区。
///
/// 三层结构对应三件事：**看哪儿**（分支与刷新）、**看什么**（变更列表与历史）、
/// **干什么**（暂存 / 撤销 / 提交）。diff 不另开一页，而是替换掉中间那块列表——
/// 面板只有 320~900 宽，再分一栏给 diff 就谁都不够用了。
///
/// 所有 git 命令都在服务端跑：客户端没有本地命令执行通道，仓库也在服务端机器上。
/// 这里只负责"把状态画出来、把动作发出去"。
class GitPane extends ConsumerStatefulWidget {
  const GitPane({super.key});

  @override
  ConsumerState<GitPane> createState() => _GitPaneState();
}

/// 面板中间那块显示什么。
enum _GitView { changes, history }

class _GitPaneState extends ConsumerState<GitPane> {
  _GitView _view = _GitView.changes;

  /// 正在看的 diff。null 表示看列表。
  GitDiffKey? _selected;

  /// 提交信息。放在面板状态里而不是提交框自己的 State：提交成功要清空，
  /// 而清空发生在动作回调里，跨 widget 拿 controller 比把它们提到这里更绕。
  final TextEditingController _message = TextEditingController();
  final FocusNode _messageFocus = FocusNode();

  /// 有请求在飞。串行化写操作的第一道闸：按钮在请求期间禁用，
  /// 第二道是服务端 git 自己的 `index.lock`。
  bool _busy = false;

  @override
  void dispose() {
    _message.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 认"最后一个有归属的项目"：中栏切到录音 / 设置 / 记忆时，这个面板不该空掉。
    final projectId = ref.watch(shellProjectMemoProvider);

    // 切回 Git 标签就刷一次：构建 / 提交 / 外部编辑器都可能在面板不可见时改了工作区，
    // 而我们没有文件监听（inotify 跨平台差异大，大仓库成本也高）。
    ref.listen(filePaneTabProvider.select((state) => state.activeTab?.kind), (
      previous,
      next,
    ) {
      if (next != FilePaneTab.git || previous == FilePaneTab.git) {
        return;
      }
      if (projectId.isEmpty) {
        return;
      }
      ref.invalidate(gitStatusProvider(projectId));
      ref.invalidate(gitLogProvider);
    });

    if (projectId.isEmpty) {
      return const _PaneHint(
        icon: Icons.commit_outlined,
        title: '先在左侧选择一个项目',
        subtitle: 'Git 面板作用于当前项目所在的仓库',
      );
    }

    final statusAsync = ref.watch(gitStatusProvider(projectId));
    // 用 `value` 而不是 `asData?.value`：失效重取时状态会短暂处于 AsyncLoading
    // 但仍带着上一次的值，取 `asData` 会让分支栏与提交区在一帧里退回"读取中"，
    // 而下面的列表仍在显示旧数据——同一个面板里两块内容说两套话。
    final status = statusAsync.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _BranchBar(
          status: status,
          busy: _busy,
          onRefresh: statusAsync.isLoading ? null : () => _refresh(projectId),
        ),
        if (status != null && status.detached) const _DetachedNotice(),
        _ViewSwitch(
          view: _view,
          changes: status?.changeCount ?? 0,
          onChanged: (view) => setState(() {
            _view = view;
            _selected = null;
          }),
        ),
        Expanded(child: _body(projectId, statusAsync)),
        if (_view == _GitView.changes)
          GitCommitBox(
            controller: _message,
            focusNode: _messageFocus,
            busy: _busy,
            // 不能写成 `status?.commitBlockedReason ?? '读取中'`：
            // `commitBlockedReason` 为 null 正是"可以提交"，和"状态还没到"是两件事，
            // 合并之后按钮会永远禁用。
            blockedReason: status == null
                ? '正在读取仓库状态'
                : status.commitBlockedReason,
            onCommit: () => _commit(projectId),
          ),
      ],
    );
  }

  Widget _body(String projectId, AsyncValue<GitStatusReport> statusAsync) {
    final selected = _selected;
    if (selected != null) {
      return GitDiffView(
        diffKey: selected,
        onBack: () => setState(() => _selected = null),
      );
    }

    return switch (statusAsync) {
      AsyncValue(:final error?) => _ErrorState(
        error: error,
        onRetry: () => _refresh(projectId),
      ),
      AsyncValue(:final value?) => switch (_view) {
        _GitView.changes =>
          value.repo
              ? GitChangeList(
                  status: value,
                  busy: _busy,
                  onSelect: (change, staged) => setState(() {
                    // 已暂存看 `--cached`，未暂存/未跟踪看工作区。
                    _selected = (
                      projectId: projectId,
                      path: change.path,
                      staged: staged,
                      commit: null,
                    );
                  }),
                  onStage: (paths) => _run(
                    () => ref.read(gitActionsProvider).stage(projectId, paths),
                  ),
                  onUnstage: (paths) => _run(
                    () =>
                        ref.read(gitActionsProvider).unstage(projectId, paths),
                  ),
                  onDiscard: (paths) => _discard(projectId, paths),
                )
              // 不是仓库是**状态**不是错误：普通项目目录本来就该走到这里。
              : _PaneHint(
                  icon: Icons.folder_off_outlined,
                  title: '这里还不是 Git 仓库',
                  subtitle: value.reason ?? '当前项目目录不是仓库根',
                ),
        _GitView.history =>
          value.repo
              ? GitHistoryView(
                  projectId: projectId,
                  onSelect: (commit) => setState(() {
                    _selected = (
                      projectId: projectId,
                      path: '',
                      staged: false,
                      commit: commit.hash,
                    );
                  }),
                )
              : _PaneHint(
                  icon: Icons.history_rounded,
                  title: '这里还不是 Git 仓库',
                  subtitle: value.reason ?? '当前项目目录不是仓库根',
                ),
      },
      _ => const Center(
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    };
  }

  void _refresh(String projectId) {
    ref.invalidate(gitStatusProvider(projectId));
    ref.invalidate(gitLogProvider);
  }

  Future<void> _commit(String projectId) async {
    final message = _message.text.trim();
    if (message.isEmpty) {
      _toast('写一句提交信息再提交');
      return;
    }

    await _run(() async {
      final result = await ref
          .read(gitActionsProvider)
          .commit(projectId, message);
      _message.clear();
      // 提交完把 diff 收起：刚才看的那份差异已经被这次提交吃掉了。
      if (mounted) {
        setState(() => _selected = null);
      }
      _toast('已提交 ${result.commit.shortHash}');
    });
  }

  /// 撤销是不可恢复的：必须在同一次交互里说清"要丢什么"，而不是点了才提示。
  Future<void> _discard(String projectId, List<String> paths) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销这些改动？'),
        content: Text(
          paths.length == 1
              ? '「${paths.single}」会回到最后一次提交的状态，'
                    '已暂存与未暂存的改动都会丢失，无法恢复。'
              : '${paths.length} 个文件会回到最后一次提交的状态，'
                    '已暂存与未暂存的改动都会丢失，无法恢复。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    await _run(() async {
      await ref.read(gitActionsProvider).discard(projectId, paths);
      if (mounted) {
        setState(() => _selected = null);
      }
    });
  }

  /// 统一跑一次写操作：请求期间禁按钮，失败把服务端的 hint 原样给用户。
  ///
  /// 不自己编"操作失败"这种话：服务端的提示里写着具体原因（没有暂存内容、
  /// 仓库正在 merge、路径越界……），那才是用户要的信息。
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (error) {
      _toast(error.userMessage);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

/// 顶部一行：当前分支、变更条数、刷新。
class _BranchBar extends StatelessWidget {
  const _BranchBar({
    required this.status,
    required this.busy,
    required this.onRefresh,
  });

  final GitStatusReport? status;
  final bool busy;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(
        kPaneEdgeInset,
        6,
        kPaneContentInset,
        6,
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.call_split_rounded,
            size: kPaneHeaderIconSize,
            color: palette.text.tertiary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              status?.branchLabel ?? '…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: AppFontSize.sm,
                fontWeight: AppWeight.semiBold,
                color: palette.text.primary,
              ),
            ),
          ),
          if (status != null && status!.changeCount > 0) ...<Widget>[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                '${status!.changeCount}',
                style: TextStyle(
                  fontSize: AppFontSize.xs,
                  fontWeight: AppWeight.semiBold,
                  color: palette.text.secondary,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            ),
          IconButton(
            tooltip: '刷新状态',
            onPressed: onRefresh,
            style: shellIconButtonStyle(
              minimumSize: const Size.square(kPaneHeaderButtonSize),
            ),
            iconSize: kPaneHeaderIconSize,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}

/// 游离 HEAD 的警告条。
///
/// 不折进分支栏文字里：游离 HEAD 下提交照样能成功，但提交不在任何分支上，
/// 用户下次切走就找不到了——这种"能做但会丢"的状态必须单独占一行。
class _DetachedNotice extends StatelessWidget {
  const _DetachedNotice();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        kPaneEdgeInset,
        0,
        kPaneContentInset,
        6,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: palette.status.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.warning_amber_rounded,
            size: kPaneHeaderIconSize,
            color: palette.status.warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'HEAD 处于游离状态：新提交不在任何分支上',
              style: TextStyle(
                fontSize: AppFontSize.xs,
                color: palette.text.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「变更 / 历史」两级切换。
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({
    required this.view,
    required this.changes,
    required this.onChanged,
  });

  final _GitView view;

  /// 变更条数：挂在「变更」上，一眼知道有没有待办。
  final int changes;

  final ValueChanged<_GitView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPaneEdgeInset,
        0,
        kPaneContentInset,
        8,
      ),
      child: Row(
        children: <Widget>[
          _Segment(
            label: changes > 0 ? '变更 $changes' : '变更',
            active: view == _GitView.changes,
            onTap: () => onChanged(_GitView.changes),
          ),
          const SizedBox(width: 6),
          _Segment(
            label: '历史',
            active: view == _GitView.history,
            onTap: () => onChanged(_GitView.history),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);

    return Material(
      color: active
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.75)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppFontSize.sm,
              fontWeight: active ? AppWeight.semiBold : AppWeight.medium,
              color: active ? palette.text.primary : palette.text.tertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板内的空态 / 提示。
class _PaneHint extends StatelessWidget {
  const _PaneHint({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kPaneEdgeInset,
          16,
          kPaneContentInset,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 26, color: palette.text.tertiary),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.base,
                fontWeight: AppWeight.semiBold,
                color: palette.text.secondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                color: palette.text.tertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 出错：原样展示服务端 hint，并给一次手动重试。
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final message = error is ApiException
        ? (error as ApiException).userMessage
        : '$error';

    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kPaneEdgeInset,
          16,
          kPaneContentInset,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline_rounded,
              size: 26,
              color: palette.status.danger,
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                color: palette.text.secondary,
              ),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
