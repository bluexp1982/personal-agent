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

/// 执行授权列表：按作用域分组，显示来源审批与剩余时间，可撤销。
///
/// 授权只跳过"询问"，不改变"判定"：所以这一页的文案必须写"下一次同类操作
/// 会重新询问"，而不是"允许这类操作"。
class GrantsPage extends ConsumerStatefulWidget {
  const GrantsPage({super.key});

  @override
  ConsumerState<GrantsPage> createState() => _GrantsPageState();
}

class _GrantsPageState extends ConsumerState<GrantsPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final grants = ref.watch(memoryGrantsProvider);
    final text = AppText.of(context);

    return AppPageScaffold(
      appBar: const MobileAppBar(title: '执行授权'),
      body: grants.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text(
            error is ApiException ? error.hint : '授权暂时不可用',
            style: text.hint,
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '没有生效中的授权。你可以在工具审批卡上勾选"记住"来减少重复询问',
                  textAlign: TextAlign.center,
                  style: text.hint,
                ),
              ),
            );
          }

          final now = DateTime.now().millisecondsSinceEpoch;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              for (final scope in GrantScope.values) ..._group(scope, items, now, text),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _group(GrantScope scope, List<Grant> all, int now, AppText text) {
    final items = all.where((grant) => grant.scope == scope).toList();
    if (items.isEmpty) {
      return const <Widget>[];
    }

    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text('${scope.label} · ${items.length} 条', style: text.meta),
      ),
      for (final grant in items) _row(grant, now, text),
    ];
  }

  Widget _row(Grant grant, int now, AppText text) {
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
            children: <Widget>[
              Expanded(child: Text(grant.tool, style: text.row)),
              _riskTag(grant.risk, palette, text),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '剩余 ${grant.remaining(now)} · 命中 ${grant.hitCount} 次',
            style: text.meta,
          ),
          const SizedBox(height: 2),
          Text('来源审批 ${grant.approvedBy}', style: text.meta),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : () => _revoke(grant),
              child: const Text('撤销'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _riskTag(GrantRisk risk, AppPalette palette, AppText text) {
    final color = switch (risk) {
      GrantRisk.read => palette.status.neutral,
      GrantRisk.reversibleWrite => palette.status.info,
      GrantRisk.irreversibleWrite => palette.status.danger,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: palette.status.borderOf(color)),
      ),
      child: Text(risk.label, style: text.badge.copyWith(color: color)),
    );
  }

  Future<void> _revoke(Grant grant) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销这条授权？'),
        content: const Text('下一次同类操作会重新询问你。'),
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
    setState(() => _busy = true);
    try {
      await api.revokeGrant(grant.id);
      ref.invalidate(memoryGrantsProvider);
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.hint)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}
