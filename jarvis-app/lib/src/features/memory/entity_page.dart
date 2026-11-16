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

/// 实体页：一句话状态快照 + 时间线 + 合并/拆分。
///
/// 快照为空说明夜间整理还没跑过——不显示"暂无内容"这种模糊文案，
/// 直接告诉用户它什么时候会更新。
class EntityDetailPage extends ConsumerStatefulWidget {
  const EntityDetailPage({super.key, required this.entityId});

  final String entityId;

  @override
  ConsumerState<EntityDetailPage> createState() => _EntityPageState();
}

class _EntityPageState extends ConsumerState<EntityDetailPage> {
  final Set<String> _selected = <String>{};
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(memoryEntityProvider(widget.entityId));
    final text = AppText.of(context);

    return AppPageScaffold(
      appBar: MobileAppBar(
        title: '实体',
        actions: <Widget>[
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _split,
              child: Text('拆成新实体（${_selected.length}）', style: text.row),
            ),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text(
            error is ApiException ? error.hint : '实体暂时不可用',
            style: text.hint,
          ),
        ),
        data: (detail) {
          if (detail == null) {
            return Center(child: Text('这个实体不存在', style: text.hint));
          }
          return _body(detail, text);
        },
      ),
    );
  }

  Widget _body(EntityDetail detail, AppText text) {
    final entity = detail.entity;
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(entity.name, style: text.cardTitle)),
            TextButton(
              onPressed: _busy ? null : () => _rename(entity),
              child: const Text('改名'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _Tag(text: entity.entityType.label, base: scheme.primary, palette: palette),
            _Tag(text: entity.status.label, base: palette.status.info, palette: palette),
            _Tag(
              text: '置信度 ${entity.confidence.toStringAsFixed(2)}',
              base: palette.status.neutral,
              palette: palette,
            ),
          ],
        ),
        if (entity.aliases.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('别名：${entity.aliases.join('、')}', style: text.meta),
        ],
        const SizedBox(height: 20),
        Text('当前状态', style: text.section),
        const SizedBox(height: 8),
        if (entity.hasSnapshot)
          Text(entity.snapshot, style: text.body)
        else
          Text('还没有快照。夜间整理会为它生成一句话状态。', style: text.hint),
        if (entity.snapshotAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '更新于 ${formatDate(entity.snapshotAt!)} 夜间',
              style: text.meta,
            ),
          ),
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            Text('时间线', style: text.section),
            const Spacer(),
            Text('${detail.timeline.length} 条', style: text.meta),
          ],
        ),
        const SizedBox(height: 8),
        if (detail.timeline.isEmpty)
          Text('还没有关联的记忆', style: text.hint)
        else
          for (final memory in detail.timeline) _timelineRow(memory, text),
        if (detail.timeline.length >= 50)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('仅显示最近 50 条', style: text.meta),
          ),
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: _busy ? null : () => _mergePicker(entity),
              child: const Text('合并到…'),
            ),
            const SizedBox(width: 8),
            Text('勾选时间线里的条目可以拆成新实体', style: text.meta),
          ],
        ),
      ],
    );
  }

  Widget _timelineRow(Memory memory, AppText text) {
    final selected = _selected.contains(memory.id);

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => openMemoryDetail(context, memory.id),
      onLongPress: () {
        setState(() {
          if (selected) {
            _selected.remove(memory.id);
          } else {
            _selected.add(memory.id);
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                memory.content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.row,
              ),
            ),
            const SizedBox(width: 8),
            Text(formatDate(memory.createdAt), style: text.meta),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(Entity entity) async {
    final controller = TextEditingController(text: entity.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('改个名字'),
        content: TextField(controller: controller, autofocus: true),
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

    final api = ref.read(memoryApiProvider);
    if (api == null || name == null || name.isEmpty || name == entity.name) {
      return;
    }
    setState(() => _busy = true);
    try {
      await api.updateEntity(entity.id, name: name);
      _refresh(entity.id);
    } on ApiException catch (error) {
      _snack(error.hint);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _mergePicker(Entity entity) async {
    // 必须 await：`read` 拿到的是 AsyncValue，第一次读时还在 loading，
    // 直接取 `.value` 会永远得到空列表，合并入口就变成"点了没反应"。
    final page = await ref.read(
      memoryEntitiesProvider((
        type: entity.entityType,
        status: null,
        query: '',
      )).future,
    );
    final candidates = page.items
        .where((item) => item.id != entity.id)
        .toList();
    if (!mounted) {
      return;
    }

    if (candidates.isEmpty) {
      _snack('没有可合并的同类实体');
      return;
    }

    final target = await showDialog<Entity>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('合并到哪个实体？'),
        children: <Widget>[
          for (final item in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(item),
              child: Text(item.name),
            ),
        ],
      ),
    );
    if (target == null || !mounted) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认合并？'),
        content: Text(
          '「${entity.name}」的记忆会全部转投到「${target.name}」，'
          '被合并方不再出现在列表里。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('合并'),
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
      await api.mergeEntities(sourceId: entity.id, targetId: target.id);
      _refresh(target.id);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on ApiException catch (error) {
      _snack(error.hint);
    }
  }

  Future<void> _split() async {
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('拆成新实体'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新实体的名字'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('拆分'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) {
      return;
    }

    try {
      final detail = await api.splitEntity(
        widget.entityId,
        memoryIds: _selected.toList(),
        name: name.isEmpty ? null : name,
      );
      setState(_selected.clear);
      _refresh(widget.entityId);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => EntityDetailPage(entityId: detail.entity.id),
          ),
        );
      }
    } on ApiException catch (error) {
      _snack(error.hint);
    }
  }

  void _refresh(String id) {
    ref.invalidate(memoryEntityProvider(id));
    ref.invalidate(memoryEntitiesProvider);
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

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.base, required this.palette});

  final String text;
  final Color base;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
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
