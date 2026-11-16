import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';

/// 倒计时进入这个阈值后改用 `mm:ss` 并标红。
const int _urgentCountdownMs = 120 * 1000;

/// 待确认卡片：任务级（合并）与工具级（单次调用）共用。
///
/// 工具级且服务端标记 `rememberable` 时，多给一个「本任务内不再询问这类操作」：
/// 勾选结果随 `onApprove` 一起交出去，由 worker 在本任务内记住对应规则。
class ApprovalCard extends StatefulWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final ApprovalView approval;
  final bool busy;

  /// 参数是「本任务内不再询问这类操作」。
  /// 第一个参数是「记住」，第二个是作用域线缆值（`task`/`session`/`project`，
  /// 未记住时为 null）。
  final void Function(bool remember, String? rememberScope) onApprove;
  final VoidCallback onReject;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  bool _remember = false;

  /// 记住多久。默认本任务内；只有记住时才显示选择。
  String _scope = 'task';

  @override
  void didUpdateWidget(covariant ApprovalCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一张卡就把勾选清掉：上一次的"记住"不该顺延到另一条规则。
    if (oldWidget.approval.id != widget.approval.id) {
      _remember = false;
      _scope = 'task';
    }
  }

  @override
  Widget build(BuildContext context) {
    final approval = widget.approval;
    final busy = widget.busy;
    final scheme = Theme.of(context).colorScheme;
    final remaining =
        approval.expiresAt - DateTime.now().millisecondsSinceEpoch;
    final tool = approval.tool;
    final isTool = approval.isToolScope;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.tertiary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.pan_tool_outlined, size: 18, color: scheme.tertiary),
              const SizedBox(width: 8),
              // 用 Expanded 代替 Spacer：标题与倒计时都不可伸缩时，
              // 字体放大一点就会把这一行撑爆。
              Expanded(
                child: Text(
                  isTool ? '需要你确认这一步' : '需要你确认',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: AppWeight.semiBold),
                ),
              ),
              if (remaining > 0)
                Text(
                  _countdownLabel(remaining),
                  style: AppText.of(context).meta.copyWith(
                    color: isTool && remaining < _urgentCountdownMs
                        ? AppPalette.of(context).status.danger
                        : AppPalette.of(context).text.tertiary,
                    fontWeight: isTool && remaining < _urgentCountdownMs
                        ? AppWeight.medium
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (isTool)
            ..._toolRows(context, tool)
          else ...<Widget>[
            Text('动作：${approval.action}'),
            if (approval.target != null) Text('对象：${approval.target}'),
            if (approval.impact != null) Text('影响：${approval.impact}'),
            for (final preview in approval.previews)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  preview,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          if (isTool && (tool?.rememberable ?? false)) ...<Widget>[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: busy ? null : () => setState(() => _remember = !_remember),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _remember,
                      onChanged: busy
                          ? null
                          : (value) =>
                                setState(() => _remember = value ?? false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '记住这类操作，不再重复询问',
                      style: AppText.of(context).meta.copyWith(
                        color: AppPalette.of(context).text.secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 次级选择：只跳过"询问"，不改变判定；不可逆动作压根不显示勾选。
            if (_remember)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final option in const <(String, String)>[
                      ('task', '本任务内'),
                      ('session', '本会话 24 小时'),
                      ('project', '本项目 7 天'),
                    ])
                      _ScopeChip(
                        label: option.$2,
                        selected: _scope == option.$1,
                        onTap: busy
                            ? null
                            : () => setState(() => _scope = option.$1),
                      ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 14),
          // Wrap 而不是 Row：手机上两个按钮的固定宽度已经把容器占满，
          // 字体放大或文案变长时换行比溢出好。
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              TextButton(
                onPressed: busy ? null : widget.onReject,
                child: Text(isTool ? '驳回并跳过' : '拒绝'),
              ),
              FilledButton(
                onPressed: busy ? null : () => widget.onApprove(_remember, _remember ? _scope : null),
                child: Text(isTool ? '放行这一步' : '批准并继续'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 工具级审批的正文：工具名、风险等级、脱敏摘要。
  ///
  /// 摘要由服务端截断并脱敏，客户端只负责显示，**不再二次拼接命令原文**。
  List<Widget> _toolRows(BuildContext context, ApprovalToolView? tool) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    if (tool == null) {
      return <Widget>[Text('动作：${widget.approval.action}')];
    }

    return <Widget>[
      Text('工具：${tool.name}'),
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '风险：${tool.riskLabel}',
          style: text.meta.copyWith(
            color: tool.isIrreversible
                ? palette.status.danger
                : palette.text.secondary,
          ),
        ),
      ),
      if (tool.digest.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            tool.digest,
            style: text.mono(
              size: AppFontSize.sm,
              color: palette.text.secondary,
            ),
          ),
        ),
      if (widget.approval.impact != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('影响：${widget.approval.impact}'),
        ),
    ];
  }

  /// 剩余时间：不到 2 分钟用 `mm:ss`，让人对"马上超时"有感觉。
  String _countdownLabel(int remaining) {
    if (remaining < _urgentCountdownMs) {
      final seconds = (remaining / 1000).ceil();
      final minutes = seconds ~/ 60;
      final rest = seconds % 60;
      return '剩 $minutes:${rest.toString().padLeft(2, '0')} 后自动驳回';
    }
    return '${(remaining / 60000).ceil()} 分钟后过期';
  }
}

/// 作用域胶囊。与筛选胶囊同一形状，避免审批卡里出现第二套控件语言。
class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = AppText.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Text(label, style: text.row),
      ),
    );
  }
}
