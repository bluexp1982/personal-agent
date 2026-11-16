import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';

/// 一次批量删除的结果。
///
/// 逐条删除是刻意的：服务端按单资源语义返回 204/404/409，客户端只需要汇总，
/// 不用为批量操作另造一套「部分成功」的契约。
class DeleteOutcome {
  const DeleteOutcome({
    required this.deleted,
    required this.failed,
    this.firstError,
  });

  final List<String> deleted;
  final List<String> failed;

  /// 首个失败原因（面向用户），用于 SnackBar。
  final String? firstError;

  int get deletedCount => deleted.length;
  bool get hasFailures => failed.isNotEmpty;
}

/// 分批并发删除，单条失败不影响其余。
///
/// 并发上限 4：本机服务与 SQLite 写锁都吃不下几十个同时到达的 DELETE。
Future<DeleteOutcome> deleteSelected({
  required Iterable<String> ids,
  required Future<void> Function(String id) deleteOne,
  int concurrency = 4,
}) async {
  final pending = ids.toList(growable: false);
  final deleted = <String>[];
  final failed = <String>[];
  String? firstError;

  var next = 0;

  Future<void> worker() async {
    while (true) {
      // `next` 的读与自增之间没有 await：Dart 单线程事件循环下不会交错。
      final index = next;
      next += 1;
      if (index >= pending.length) {
        return;
      }

      final id = pending[index];
      try {
        await deleteOne(id);
        deleted.add(id);
      } on ApiException catch (error) {
        failed.add(id);
        firstError ??= error.userMessage;
      } catch (error) {
        failed.add(id);
        firstError ??= '$error';
      }
    }
  }

  final workers = math.min(math.max(concurrency, 1), pending.length);
  await Future.wait(<Future<void>>[
    for (var index = 0; index < workers; index += 1) worker(),
  ]);

  return DeleteOutcome(
    deleted: deleted,
    failed: failed,
    firstError: firstError,
  );
}

/// 删除结果的一句话，可直接塞进 SnackBar。
String deleteSummary(String noun, DeleteOutcome outcome) {
  if (!outcome.hasFailures) {
    return '已删除 ${outcome.deletedCount} 个$noun';
  }
  final reason = outcome.firstError ?? '未知原因';
  if (outcome.deletedCount == 0) {
    return '删除失败：$reason';
  }
  return '已删除 ${outcome.deletedCount} 个$noun，${outcome.failed.length} 个失败：$reason';
}

/// 管理态的 AppBar 动作：全选 / 取消全选 + 完成。
class SelectionAppBarActions extends StatelessWidget {
  const SelectionAppBarActions({
    super.key,
    required this.selectedCount,
    required this.selectableCount,
    required this.onToggleAll,
    required this.onDone,
  });

  final int selectedCount;

  /// 可勾选的条目数（任务页会排除执行中的任务）。
  final int selectableCount;
  final VoidCallback onToggleAll;
  final VoidCallback onDone;

  bool get _allSelected =>
      selectableCount > 0 && selectedCount >= selectableCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextButton(
          onPressed: selectableCount == 0 ? null : onToggleAll,
          child: Text(_allSelected ? '取消全选' : '全选'),
        ),
        TextButton(onPressed: onDone, child: const Text('完成')),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// 管理态底部的删除条。未选中或提交中时按钮禁用。
class SelectionDeleteBar extends StatelessWidget {
  const SelectionDeleteBar({
    super.key,
    required this.selectedCount,
    required this.busy,
    required this.onDelete,
  });

  final int selectedCount;
  final bool busy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = selectedCount > 0 && !busy;

    return Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: <Widget>[
              Text(
                '已选 $selectedCount 项',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: AppFontSize.base,
                  color: enabled
                      ? AppPalette.of(context).text.primary
                      : AppPalette.of(context).text.secondary,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: enabled ? onDelete : null,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  disabledBackgroundColor: scheme.error.withValues(alpha: 0.38),
                  disabledForegroundColor: scheme.onSurface.withValues(
                    alpha: 0.38,
                  ),
                ),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline, size: 18),
                label: Text(busy ? '删除中…' : '删除'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 删除前的二次确认。返回 `true` 才真正执行。
Future<bool> confirmDeleteDialog(
  BuildContext context, {
  required String title,
  required String message,
  required int count,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text('删除 $count 项'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
