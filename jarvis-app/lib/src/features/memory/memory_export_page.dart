import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/memory/memory_models.dart';
import '../../core/memory/memory_providers.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';

/// 导出项目记忆到 `AGENTS.md`。
///
/// 三步：选项目 → 看 diff → 写入。diff 必须展示过才能点写入：
/// 这个操作会改仓库里的文件，用户得先看见它到底改了什么。
class MemoryExportPage extends ConsumerStatefulWidget {
  const MemoryExportPage({super.key});

  @override
  ConsumerState<MemoryExportPage> createState() => _MemoryExportPageState();
}

class _MemoryExportPageState extends ConsumerState<MemoryExportPage> {
  String? _projectId;
  ExportPreview? _preview;
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectsProvider);
    final text = AppText.of(context);

    return AppPageScaffold(
      appBar: const MobileAppBar(title: '导出到 AGENTS.md'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: <Widget>[
          Text('选择仓库', style: text.section),
          const SizedBox(height: 8),
          projects.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Text(
              error is ApiException ? error.hint : '取不到项目',
              style: text.hint,
            ),
            data: (all) {
              // AGENTS.md 只对 Git 项目有意义：普通项目没有仓库可导出。
              final items = all.where((project) => project.isCode).toList();
              if (items.isEmpty) {
                return Text('还没有 Git 项目', style: text.hint);
              }
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final project in items)
                    _chip(project, text),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          if (_error != null) ...<Widget>[
            _errorBox(text),
            const SizedBox(height: 12),
          ],
          if (_preview != null) ...<Widget>[
            Row(
              children: <Widget>[
                Text('预览', style: text.section),
                const Spacer(),
                Text('${_preview!.entries} 条记忆将写入', style: text.meta),
              ],
            ),
            const SizedBox(height: 8),
            Text(_preview!.path, style: text.meta),
            const SizedBox(height: 8),
            if (_preview!.isNoop)
              Text('文件已经是这个内容，无需写入', style: text.hint)
            else
              _diff(_preview!.diff, text),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy || _preview!.isNoop ? null : _apply,
              child: const Text('写入文件'),
            ),
            const SizedBox(height: 8),
            Text(
              '这是快照，不是权威；下次导出会替换标记块内的内容。',
              style: text.hint,
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(Project project, AppText text) {
    final selected = _projectId == project.id;
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: _busy ? null : () => _previewFor(project),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Text(project.name, style: text.row),
      ),
    );
  }

  Widget _diff(String diff, AppText text) {
    final palette = AppPalette.of(context);
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
          for (final line in diff.split('\n'))
            Text(
              line,
              style: line.startsWith('+')
                  ? mono.copyWith(color: palette.status.success)
                  : line.startsWith('-')
                  ? mono.copyWith(color: palette.status.danger)
                  : mono,
            ),
        ],
      ),
    );
  }

  Widget _errorBox(AppText text) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(palette.status.danger),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: palette.status.borderOf(palette.status.danger)),
      ),
      child: Text(
        _error ?? '',
        style: text.hint.copyWith(color: palette.status.danger),
      ),
    );
  }

  Future<void> _previewFor(Project project) async {
    final api = ref.read(memoryApiProvider);
    if (api == null) {
      return;
    }
    setState(() {
      _busy = true;
      _projectId = project.id;
      _error = null;
    });
    try {
      final preview = await api.exportPreview(project.id);
      if (mounted) {
        setState(() => _preview = preview);
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _preview = null;
          _error = error.hint;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _apply() async {
    final api = ref.read(memoryApiProvider);
    final preview = _preview;
    if (api == null || preview == null) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.exportApply(
        projectId: preview.projectId,
        expectedHash: preview.contentHash,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已写入 AGENTS.md')));
      // 写完再预览一次：让界面显示"已经是这个内容"，避免用户重复点击。
      final again = await api.exportPreview(preview.projectId);
      if (mounted) {
        setState(() => _preview = again);
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          // 哈希不一致时旧预览已失效，必须重新预览。
          _preview = null;
          _error = error.code == 'conflict'
              ? '文件已被改动，请重新预览'
              : error.hint;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}
