import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/ui/app_dialog.dart';
import 'message_markdown.dart';

/// 摘要生成时间的展示口径：`2026-11-10 14:03`。
///
/// 只精确到分钟：摘要不是逐条事件，秒级精度没有信息量。
String formatCompactionTime(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// 打开上下文摘要弹窗。
///
/// 走全站通用的 [showAppDialog]：遮罩深浅、圆角、深浅色底色都不由这里决定。
///
/// 「重新整理」不在这里收窗：它要留在原地显示"整理中…"，完成后由
/// [onRegenerate] 交回最新视图原地刷新。
Future<void> showCompactionDialog(
  BuildContext context, {
  required CompactionView view,
  Future<CompactionView?> Function()? onRegenerate,
  bool busy = false,
}) {
  return showAppDialog<void>(
    context,
    builder: (_) =>
        CompactionDialog(view: view, busy: busy, onRegenerate: onRegenerate),
  );
}

/// 摘要弹窗：看摘要正文、这次整理的成本，以及上一次为什么失败。
///
/// 外壳交给 [AppDialog]（标题行、关闭钮、Esc 兜底、滚动区都在那里），
/// 这里只提供四段内容：说明行、正文、失败横幅、底部动作。
///
/// 两种形态：
/// - 有可用摘要：正文 + 元信息 + 「重新整理」；
/// - 只有失败记录：不装成"有内容"，直接把原因与时间摆出来。
///
/// **没有"关闭压缩"**：关闭后服务端不再下发压缩状态，客户端会连横条、
/// 上下文环入口和这个弹窗一起失去（一道自锁的门）。要关只能走
/// `DELETE /api/conversations/{id}/compaction`，所以界面上不提供它。
///
/// 「重新整理」是一次可观察的异步操作：按钮换成「整理中…」并禁用，
/// 结束后用回调交回来的视图原地替换内容；失败时保留旧摘要，只多一条失败原因。
class CompactionDialog extends StatefulWidget {
  const CompactionDialog({
    super.key,
    required this.view,
    this.onRegenerate,
    this.busy = false,
  });

  final CompactionView view;

  /// 重新整理，完成后交回最新视图（`null` = 这次没有可替换的内容）。
  /// 为 `null` 时不显示这枚按钮（例如只读场景）。
  final Future<CompactionView?> Function()? onRegenerate;

  /// 打开时页面是否已有一次整理在跑（此时直接进入"整理中"）。
  final bool busy;

  @override
  State<CompactionDialog> createState() => _CompactionDialogState();
}

class _CompactionDialogState extends State<CompactionDialog> {
  /// 当前展示的视图：打开时是页面那份快照，整理完成后换成回调交回来的新视图。
  late CompactionView _view = widget.view;

  /// 这一次整理还在跑。与页面的 `_compactionBusy` 分工不同：
  /// 这个只管弹窗自己的按钮文案与禁用，页面那个管环转动与防连点。
  late bool _busy = widget.busy;

  Future<void> _regenerate() async {
    final onRegenerate = widget.onRegenerate;
    if (onRegenerate == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    final next = await onRegenerate();
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      // 只在拿到新视图时替换：失败时保留旧摘要，新的失败原因由页面回读带来。
      if (next != null) {
        _view = next;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    // 高度按视口收：写死 520 在 600px 高的窗口里会连同 `insetPadding`
    // 一起溢出。下限 320 保证至少能看见两行正文与动作区。
    final maxHeight = (MediaQuery.sizeOf(context).height - 96).clamp(
      320.0,
      520.0,
    );

    return AppDialog(
      title: '上下文摘要',
      subtitle: Text(
        _metaLine(_view),
        style: text.hint.copyWith(color: palette.text.tertiary),
      ),
      maxWidth: 560,
      maxHeight: maxHeight,
      // 动作区自带内边距：`AppDialog.actions` 本身不补，与「选择目录」同源。
      actions: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            if (widget.onRegenerate != null)
              FilledButton(
                onPressed: _busy ? null : _regenerate,
                child: Text(_busy ? '整理中…' : '重新整理'),
              ),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_view.hasSummary)
            MessageMarkdown(data: _view.summary!)
          else
            Text(
              '这个会话还没有可用的摘要。',
              style: TextStyle(
                fontSize: AppFontSize.base,
                height: AppLineHeight.normal,
                color: palette.text.secondary,
              ),
            ),
          if (_view.lastFailure case final failure?) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.status.surfaceOf(palette.status.warning),
                border: Border.all(
                  color: palette.status.borderOf(palette.status.warning),
                ),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                '上次整理失败：${failure.error}'
                '（${formatCompactionTime(failure.at)}）',
                style: TextStyle(
                  fontSize: AppFontSize.sm,
                  height: AppLineHeight.normal,
                  color: palette.text.secondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 元信息：条数 · 模型 · 时间 · token。缺什么都跳过，不留空占位。
  String _metaLine(CompactionView view) {
    final parts = <String>[
      if (view.sourceMessages > 0) '更早 ${view.sourceMessages} 条',
      if (view.model case final model? when model.isNotEmpty) model,
      if (view.updatedAt case final updatedAt?) formatCompactionTime(updatedAt),
      if (view.totalTokens > 0)
        '${view.tokensEstimated ? '约 ' : ''}${view.totalTokens} tokens',
    ];
    if (parts.isEmpty) {
      return view.isPending ? '正在整理…' : '暂无摘要';
    }
    return parts.join(' · ');
  }
}
