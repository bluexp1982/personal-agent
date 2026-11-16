import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';

/// 建议卡：回答下方的"要不要我办"。
///
/// 刻意做成需要点击的卡片而不是自动建任务：模型只是提议，
/// 用户点这一下才是意图确认，也是"不擅自把建议变成订单"的落点。
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({
    super.key,
    required this.suggestion,
    required this.state,
    this.task,
    required this.onTap,
    this.onOpenTask,
  });

  final TaskSuggestion suggestion;

  /// null / creating / created / failed
  final String? state;

  /// 已经派出去的任务（按幂等键匹配）。非空时按钮变成「查看任务」，
  /// 不再回到"让用户再派一次"的对话框。
  final TaskView? task;

  final VoidCallback onTap;
  final ValueChanged<String>? onOpenTask;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final creating = state == 'creating';
    final created = state == 'created';
    final linked = task;

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '派一件事：${skillLabel(suggestion.skill)}',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: AppFontSize.base,
            color: palette.text.primary,
          ),
        ),
        if (linked != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            taskStateLabel(linked.state),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: AppFontSize.sm,
              fontWeight: AppWeight.medium,
              color: linked.state == 'failed'
                  ? palette.status.danger
                  : palette.text.secondary,
            ),
          ),
        ],
        if (suggestion.reason.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            suggestion.reason,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: AppFontSize.sm,
              color: palette.text.tertiary,
            ),
          ),
        ],
      ],
    );

    final Widget actionChild;
    VoidCallback? actionTap;
    if (creating) {
      actionTap = null;
      actionChild = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (linked != null) {
      actionTap = onOpenTask == null ? null : () => onOpenTask!(linked.id);
      actionChild = const Text('查看任务');
    } else if (created) {
      // 老状态：任务建好了但列表还没刷新出幂等键时的兜底。
      actionTap = null;
      actionChild = const Text('已创建');
    } else if (state == 'failed') {
      actionTap = onTap;
      actionChild = const Text('重试');
    } else {
      actionTap = onTap;
      actionChild = const Text('派这件事');
    }

    final action = FilledButton.tonal(onPressed: actionTap, child: actionChild);

    // 手机上的气泡只剩 200dp 左右：把按钮留在右侧会把标题挤成一列竖排，
    // 因此窄屏改成"文案在上、按钮在下"。
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 300;
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
          ),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          Icons.playlist_add_check,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: heading),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.playlist_add_check,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: heading),
                    const SizedBox(width: 8),
                    action,
                  ],
                ),
        );
      },
    );
  }
}

/// 技能名 → 用户能看懂的名字。未知技能直接显示原名，不猜。
String skillLabel(String skill) {
  return switch (skill) {
    'trip-plan' => '出行方案编排',
    'bill-explain' => '账单解读',
    _ => skill,
  };
}
