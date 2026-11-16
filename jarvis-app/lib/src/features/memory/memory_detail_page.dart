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

/// 一条记忆的详情：正文、元信息、逐条依据、编辑与删除。
///
/// 依据是这一页的重点——没有依据的记忆和被编造的记忆在界面上必须长得不一样，
/// 所以每条证据都把 `support_span` 在原文里高亮出来。
class MemoryDetailPage extends ConsumerStatefulWidget {
  const MemoryDetailPage({super.key, required this.memoryId});

  final String memoryId;

  @override
  ConsumerState<MemoryDetailPage> createState() => _MemoryDetailPageState();
}

class _MemoryDetailPageState extends ConsumerState<MemoryDetailPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(memoryDetailProvider(widget.memoryId));
    final text = AppText.of(context);

    return AppPageScaffold(
      appBar: const MobileAppBar(title: '记忆详情'),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text(
            error is ApiException ? error.hint : '记忆暂时不可用',
            style: text.hint,
          ),
        ),
        data: (detail) {
          if (detail == null) {
            return Center(child: Text('这条记忆不存在或已被删除', style: text.hint));
          }
          return _body(detail, text);
        },
      ),
    );
  }

  Widget _body(MemoryDetail detail, AppText text) {
    final memory = detail.memory;
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: Text(memory.content, style: text.body)),
            IconButton(
              tooltip: memory.pinned ? '取消置顶' : '置顶',
              onPressed: _busy ? null : () => _togglePin(memory),
              icon: Icon(
                memory.pinned
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                size: 18,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _Tag(text: memory.kind.label, palette: palette, scheme: scheme),
            _Tag(text: memory.status.label, palette: palette, scheme: scheme),
            if (memory.pinned)
              _Tag(text: '已置顶', palette: palette, scheme: scheme),
            if (memory.isPrivate)
              _Tag(
                text: '私密',
                palette: palette,
                scheme: scheme,
                color: palette.status.warning,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(_metaLine(memory), style: text.meta),
        if (memory.conflicting) ...<Widget>[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: palette.status.surfaceOf(palette.status.warning),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: palette.status.borderOf(palette.status.warning),
              ),
            ),
            child: Text(
              '存在分歧：另有同主体的不同说法',
              style: text.hint.copyWith(color: palette.status.warning),
            ),
          ),
        ],
        if (memory.isPrivate) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            '私密记忆不会进入日常对话的常驻记忆，只在明确召回时使用',
            style: text.hint,
          ),
        ],
        const SizedBox(height: 24),
        Text('依据', style: text.section),
        const SizedBox(height: 8),
        if (detail.evidence.isEmpty)
          Text('这条记忆没有留下依据', style: text.hint)
        else
          for (final evidence in detail.evidence) ...<Widget>[
            _evidenceCard(evidence, text, palette),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 16),
        if (detail.entity != null) ...<Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: () => openEntityPage(context, detail.entity!.id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.account_tree_outlined,
                    size: 16,
                    color: palette.text.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${detail.entity!.name} · ${detail.entity!.entityType.label}',
                      style: text.row,
                    ),
                  ),
                  Text('查看实体', style: text.meta),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          children: <Widget>[
            TextButton(
              onPressed: _busy ? null : () => _edit(memory),
              child: const Text('编辑'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : () => _confirmDelete(memory),
              child: Text(
                '删除',
                style: TextStyle(color: palette.status.danger),
              ),
            ),
            const Spacer(),
            Text('被召回 ${detail.recallCount} 次', style: text.meta),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Text('这条记忆准不准？', style: text.meta),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : () => _feedback(memory, useful: true),
              child: const Text('有用'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _feedback(memory, useful: false),
              child: const Text('没用'),
            ),
          ],
        ),
      ],
    );
  }

  String _metaLine(Memory memory) {
    final parts = <String>[
      memory.kind.label,
      '置信度 ${memory.confidence.toStringAsFixed(2)}',
      memory.source.label,
      formatDate(memory.createdAt),
    ];
    final scope = memory.timeScope;
    if (scope != null && scope.display.isNotEmpty) {
      parts.add(scope.display);
    }
    return parts.join(' · ');
  }

  Widget _evidenceCard(MemoryEvidence evidence, AppText text, AppPalette palette) {
    final mono = text.mono(size: AppFontSize.sm);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _highlighted(evidence, mono, palette),
          const SizedBox(height: 6),
          Text(
            '${evidence.sourceKind.wire} · ${formatDate(evidence.createdAt)}',
            style: text.meta,
          ),
        ],
      ),
    );
  }

  /// 把 `support_span` 在原文里高亮：这是"凭什么这么记"的唯一视觉证据。
  Widget _highlighted(
    MemoryEvidence evidence,
    TextStyle mono,
    AppPalette palette,
  ) {
    final quote = evidence.quote;
    final span = evidence.supportSpan?.trim() ?? '';

    if (span.isEmpty || !quote.contains(span)) {
      return SelectableText(quote, style: mono);
    }

    final start = quote.indexOf(span);
    final before = quote.substring(0, start);
    final after = quote.substring(start + span.length);

    return SelectableText.rich(
      TextSpan(
        style: mono,
        children: <TextSpan>[
          if (before.isNotEmpty) TextSpan(text: before),
          TextSpan(
            text: span,
            style: mono.copyWith(
              color: palette.status.info,
              fontWeight: AppWeight.semiBold,
            ),
          ),
          if (after.isNotEmpty) TextSpan(text: after),
        ],
      ),
    );
  }

  Future<void> _togglePin(Memory memory) async {
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await api.update(memory.id, pinned: !memory.pinned);
      _refresh(memory.id);
    } on ApiException catch (error) {
      _snack(error.hint);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _edit(Memory memory) async {
    final controller = TextEditingController(text: memory.content);
    final updated = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改记忆'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(hintText: '这条记忆应该怎么写'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (updated == null || updated.isEmpty || updated == memory.content) {
      return;
    }
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await api.update(memory.id, content: updated);
      _refresh(memory.id);
    } on ApiException catch (error) {
      _snack(error.hint);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmDelete(Memory memory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条记忆？'),
        // 文案必须写清后果：用户以为只是从列表里消失，结果发现对话里还在用。
        content: const Text('删除后，它不会再出现在回答里。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
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
    setState(() => _busy = true);
    try {
      await api.delete(memory.id);
      ref.invalidate(memoryStateProvider);
      ref.invalidate(memoryListProvider);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on ApiException catch (error) {
      _snack(error.hint);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _feedback(Memory memory, {required bool useful}) async {
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await api.feedback(memory.id, useful: useful);
      _refresh(memory.id);
      _snack(useful ? '已记为有用' : '已记为没用，召回权重会下调');
    } on ApiException catch (error) {
      _snack(error.hint);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _refresh(String id) {
    ref.invalidate(memoryDetailProvider(id));
    ref.invalidate(memoryListProvider);
    ref.invalidate(memoryStateProvider);
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

/// 状态/类型胶囊。
class _Tag extends StatelessWidget {
  const _Tag({
    required this.text,
    required this.palette,
    required this.scheme,
    this.color,
  });

  final String text;
  final AppPalette palette;
  final ColorScheme scheme;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final base = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(base),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: palette.status.borderOf(base)),
      ),
      child: Text(
        text,
        style: AppText.of(context).badge.copyWith(color: base),
      ),
    );
  }
}
