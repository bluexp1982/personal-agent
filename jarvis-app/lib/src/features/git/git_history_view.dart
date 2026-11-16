import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/git_models.dart';
import '../../core/git_providers.dart';
import '../conversations/conversations_page.dart' show formatTime;
import '../shell/shell_layout_state.dart';

/// 提交历史：短 hash + 标题 + 作者/时间，点一条看该提交的 diff。
///
/// 不做无限滚动：一页 50 条，滚到底提示"只显示最近 50 次提交"。
/// 面板是"审查刚写完的这一摊"，不是 gitk——要翻很久以前的提交，终端更合适。
class GitHistoryView extends ConsumerWidget {
  const GitHistoryView({
    super.key,
    required this.projectId,
    required this.onSelect,
  });

  final String projectId;

  /// 点某条提交：由外壳决定把 diff 显示在哪儿。
  final ValueChanged<GitCommitSummary> onSelect;

  static const int _limit = 50;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final async = ref.watch(
      gitLogProvider((projectId: projectId, limit: _limit)),
    );

    return switch (async) {
      AsyncValue(:final error?) => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kPaneEdgeInset,
            16,
            kPaneContentInset,
            24,
          ),
          child: Text(
            error is ApiException ? error.userMessage : '$error',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppFontSize.sm,
              color: palette.text.secondary,
            ),
          ),
        ),
      ),
      AsyncValue(:final value?) =>
        value.commits.isEmpty
            ? Center(
                child: Text(
                  '仓库还没有任何提交',
                  style: TextStyle(
                    fontSize: AppFontSize.sm,
                    color: palette.text.tertiary,
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: value.commits.length + (value.hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= value.commits.length) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(
                        kPaneEdgeInset + 2,
                        8,
                        kPaneContentInset,
                        8,
                      ),
                      child: Text(
                        '只显示最近 $_limit 次提交',
                        style: TextStyle(
                          fontSize: AppFontSize.xs,
                          color: palette.text.tertiary,
                        ),
                      ),
                    );
                  }
                  final commit = value.commits[index];
                  return _CommitRow(
                    commit: commit,
                    onTap: () => onSelect(commit),
                  );
                },
              ),
      _ => const Center(
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    };
  }
}

class _CommitRow extends StatefulWidget {
  const _CommitRow({required this.commit, required this.onTap});

  final GitCommitSummary commit;
  final VoidCallback onTap;

  @override
  State<_CommitRow> createState() => _CommitRowState();
}

class _CommitRowState extends State<_CommitRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final commit = widget.commit;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: _hovering
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
            : Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              kPaneEdgeInset + 2,
              5,
              kPaneContentInset,
              5,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    commit.shortHash,
                    style: TextStyle(
                      fontFamily: AppMono.family,
                      fontFamilyFallback: AppMono.fallback,
                      fontSize: AppFontSize.xs,
                      color: palette.text.tertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        commit.subject.isEmpty ? '(无提交信息)' : commit.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.base,
                          color: palette.text.primary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '${commit.author} · ${formatTime(commit.timeMs)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.xs,
                          color: palette.text.tertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
