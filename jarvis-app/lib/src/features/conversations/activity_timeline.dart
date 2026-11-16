import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';

/// 一轮回答的执行过程：折叠时一行摘要，展开后逐条列出做过什么。
///
/// 默认折叠是刻意的：展开后是一屏流水，先摊开会把回答本身挤到下面去。
/// 流式期间头部那行会跟着最新一步变化，用户不展开也知道现在在干什么。
class ActivityTimeline extends StatefulWidget {
  const ActivityTimeline({
    super.key,
    required this.steps,
    this.streaming = false,
  });

  /// 按发生顺序排好的步骤。为空时整个组件不渲染。
  final List<ChatStep> steps;

  /// 正在生成：头部显示"当前在做什么"，而不是"执行了几步"。
  final bool streaming;

  @override
  State<ActivityTimeline> createState() => _ActivityTimelineState();
}

class _ActivityTimelineState extends State<ActivityTimeline> {
  bool _expanded = false;

  /// 头部摘要。
  ///
  /// 流式中说"正在做什么"——那时用户关心的是进度；收尾后说"做了几步"。
  /// 整轮耗时由消息元信息那行（"已完成，用时 1 分 36 秒"）负责，
  /// 这里再说一遍只是重复。
  String get _summary {
    final steps = widget.steps;
    final current = steps.lastWhere(
      (step) => step.running,
      orElse: () => steps.last,
    );

    if (widget.streaming) {
      return '${current.label} · 已执行 ${steps.length} 步';
    }

    return '执行了 ${steps.length} 个步骤';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.steps.isEmpty) {
      return const SizedBox.shrink();
    }

    final message = AppPalette.of(context).message;
    final metaStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontSize: AppFontSize.sm,
      height: AppLineHeight.tight,
      color: message.meta,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 14,
                  color: message.meta,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...<Widget>[
          const SizedBox(height: 4),
          // 限高 + 内部滚动：一次检索加改文件可能有十几步，
          // 不限高会把整段对话推走，最多给 240dp。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final step in widget.steps) _StepRow(step: step),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 一步：状态位 + 文案 + 耗时。
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final ChatStep step;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = AppPalette.of(context).message;
    final color = step.ok ? message.meta : scheme.error;

    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontSize: AppFontSize.sm,
      height: AppLineHeight.tight,
      color: step.ok ? message.meta : scheme.error,
    );
    final timeStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontSize: AppFontSize.xs,
      height: AppLineHeight.tight,
      color: message.meta,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 12,
            height: 12,
            child: step.running
                ? CircularProgressIndicator(
                    strokeWidth: 1.4,
                    color: message.meta,
                  )
                : Icon(
                    step.ok
                        ? Icons.check_rounded
                        : Icons.error_outline_rounded,
                    size: 12,
                    color: color,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            // 失败原因放 tooltip：它常带上游 code / request_id，
            // 摊开会把一行撑满，但排查时必须能看到。
            child: step.error == null
                ? Text(
                    step.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  )
                : Tooltip(
                    message: step.error!,
                    child: Text(
                      step.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: labelStyle,
                    ),
                  ),
          ),
          if (!step.running && step.elapsedMs > 0) ...<Widget>[
            const SizedBox(width: 8),
            Text(_formatStepMs(step.elapsedMs), style: timeStyle),
          ],
        ],
      ),
    );
  }
}

/// 单步耗时：毫秒级给 `12ms`，秒级给 `1.2s`。
String _formatStepMs(int milliseconds) {
  if (milliseconds < 1000) {
    return '${milliseconds}ms';
  }
  return '${(milliseconds / 1000).toStringAsFixed(1)}s';
}

