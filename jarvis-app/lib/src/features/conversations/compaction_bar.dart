import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';

/// 横条文案。抽成纯函数是为了能直接单测三种状态，不必 pump 整个页面。
String compactionBarLabel(CompactionView view) {
  if (view.hasSummary) {
    return '更早 ${view.sourceMessages} 条对话已整理为摘要';
  }
  if (view.isPending) {
    return '正在整理更早的对话…';
  }
  return '更早的对话整理失败';
}

/// 消息流里的压缩边界。
///
/// 位置来自 `anchor_message_id`：插在那条"第一条没被折叠"的消息**之前**。
/// 它不是一条消息、也不参与历史分页——只是一道分隔，告诉用户
/// "上面那些内容已经不在模型的上下文里了，但原文还在"。
///
/// 没有可用摘要、也没有失败记录时调用方不渲染它；这里只负责画。
class CompactionBar extends StatefulWidget {
  const CompactionBar({super.key, required this.view, this.onOpen});

  final CompactionView view;
  final VoidCallback? onOpen;

  @override
  State<CompactionBar> createState() => _CompactionBarState();
}

class _CompactionBarState extends State<CompactionBar> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    // 只有"失败但没有可用摘要"时才用警示色：成功摘要旁边挂一条旧失败记录
    // 不该把整条横条染成告警——那会让人以为这次也坏了。
    final failedOnly = !widget.view.hasSummary && !widget.view.isPending;
    final accent = failedOnly ? palette.status.warning : palette.text.tertiary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          Expanded(child: _rule(scheme.outlineVariant)),
          const SizedBox(width: 12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: GestureDetector(
              onTap: widget.onOpen,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _hovering
                      ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (failedOnly) ...<Widget>[
                      Icon(
                        Icons.error_outline,
                        size: 13,
                        color: accent,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      compactionBarLabel(widget.view),
                      style: TextStyle(
                        fontSize: AppFontSize.sm,
                        height: AppLineHeight.tight,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '查看',
                      style: TextStyle(
                        fontSize: AppFontSize.sm,
                        height: AppLineHeight.tight,
                        fontWeight: AppWeight.medium,
                        color: palette.text.control,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _rule(scheme.outlineVariant)),
        ],
      ),
    );
  }

  Widget _rule(Color color) => Container(
    height: 1,
    color: color.withValues(alpha: 0.5),
  );
}
