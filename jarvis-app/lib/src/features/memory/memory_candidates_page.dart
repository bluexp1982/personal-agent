import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/memory/memory_models.dart';
import '../../core/memory/memory_providers.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import 'memory_navigation.dart';

/// 候选确认：按批次展示，可单条或批量接受/拒绝，也可整批撤销。
///
/// 候选不是独立表，只是 `status=candidate` 的记忆；"批次"只是界面上把一次抽取
/// 当成一个整体，撤销本批走 `POST /api/memories/batches/{id}/revoke`。
class MemoryCandidatesPage extends ConsumerStatefulWidget {
  const MemoryCandidatesPage({super.key});

  @override
  ConsumerState<MemoryCandidatesPage> createState() =>
      _MemoryCandidatesPageState();
}

class _MemoryCandidatesPageState extends ConsumerState<MemoryCandidatesPage> {
  final Set<String> _selected = <String>{};
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final batches = ref.watch(memoryCandidatesProvider);
    final text = AppText.of(context);

    return AppPageScaffold(
      appBar: MobileAppBar(
        title: '待确认的记忆',
        actions: <Widget>[
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _decide(_selected.toList(), accept: true),
              child: Text('接受 ${_selected.length} 条', style: text.row),
            ),
        ],
      ),
      body: batches.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text(
            error is ApiException ? error.hint : '记忆暂时不可用',
            style: text.hint,
          ),
        ),
        data: (batches) {
          if (batches.isEmpty) {
            return Center(child: Text('没有待确认的记忆', style: text.hint));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              for (final batch in batches) _batch(batch, text),
            ],
          );
        },
      ),
    );
  }

  Widget _batch(CandidateBatch batch, AppText text) {
    final palette = AppPalette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Row(
            children: <Widget>[
              GestureDetector(
                onTap: () => _toggleBatch(batch),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.check_box_outlined,
                      size: 16,
                      color: palette.text.tertiary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${batch.sourceLabel} · ${formatDate(batch.createdAt)} · '
                      '${batch.items.length} 条',
                      style: text.meta,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _busy || batch.batchId == null
                    ? null
                    : () => _revoke(batch.batchId!),
                child: const Text('撤销本批'),
              ),
            ],
          ),
        ),
        for (final memory in batch.items) _row(memory, text),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _row(Memory memory, AppText text) {
    final palette = AppPalette.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  memory.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.row,
                ),
              ),
              if (memory.isPrivate)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: palette.status.surfaceOf(palette.status.warning),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: palette.status.borderOf(palette.status.warning),
                    ),
                  ),
                  child: Text(
                    '私密',
                    style: text.badge.copyWith(color: palette.status.warning),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${memory.kind.label} · 置信度 ${memory.confidence.toStringAsFixed(2)}',
            style: text.meta,
          ),
          if (memory.isPrivate)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('不会进入日常对话的常驻记忆', style: text.hint),
            ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _decide(<String>[memory.id], accept: true),
                child: const Text('接受'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _decide(<String>[memory.id], accept: false),
                child: const Text('拒绝'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => openMemoryDetail(context, memory.id),
                child: const Text('看依据'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _toggleBatch(CandidateBatch batch) {
    final ids = batch.items.map((memory) => memory.id).toSet();
    setState(() {
      if (ids.every(_selected.contains)) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  Future<void> _decide(List<String> ids, {required bool accept}) async {
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await api.decide(ids: ids, accept: accept);
      if (!mounted) {
        return;
      }
      setState(_selected.clear);
      ref.invalidate(memoryCandidatesProvider);
      ref.invalidate(memoryListProvider);
      ref.invalidate(memoryStateProvider);
      _snack(
        accept
            ? '已接受 ${result.accepted} 条，跳过 ${result.skipped.length} 条'
            : '已拒绝 ${result.rejected} 条',
      );
    } on ApiException catch (error) {
      _snack(error.hint);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _revoke(String batchId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销这一批？'),
        content: const Text('这一批记忆会转为已归档，不再出现在回答里。'),
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

    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    try {
      final result = await api.revokeBatch(batchId);
      if (!mounted) {
        return;
      }
      ref.invalidate(memoryCandidatesProvider);
      _snack('已撤销 ${result.revoked} 条');
    } on ApiException catch (error) {
      _snack(error.hint);
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
