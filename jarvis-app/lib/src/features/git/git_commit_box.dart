import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../shell/shell_layout_state.dart';

/// 底部提交区：提交信息 + 提交按钮 + 禁用原因。
///
/// 禁用时**把原因写在按钮下面**而不是只把按钮变灰：灰按钮只能表达"不行"，
/// 而用户此刻要知道的是"为什么不行、下一步做什么"（没有暂存内容 / 仓库在 merge）。
class GitCommitBox extends StatelessWidget {
  const GitCommitBox({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.blockedReason,
    required this.onCommit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 有请求在飞：输入与按钮一起禁用，避免"提交中又改了一句信息"。
  final bool busy;

  /// 不能提交的原因；null 表示可以提交。
  final String? blockedReason;

  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final blocked = blockedReason != null;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        kPaneEdgeInset,
        8,
        kPaneContentInset,
        8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: !busy,
            minLines: 2,
            maxLines: 4,
            // 提交信息是"一段话"而不是单行：`Enter` 换行，提交靠按钮。
            keyboardType: TextInputType.multiline,
            style: TextStyle(
              fontSize: AppFontSize.sm,
              height: AppLineHeight.normal,
              color: palette.text.primary,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: '提交信息（第一行会被当作标题）',
              hintStyle: TextStyle(
                fontSize: AppFontSize.sm,
                color: palette.text.tertiary,
              ),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide(
                  color: scheme.primary.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              if (blocked)
                Expanded(
                  child: Text(
                    blockedReason!,
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: AppFontSize.xs,
                      color: palette.text.tertiary,
                    ),
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: blocked || busy ? null : onCommit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(
                    fontSize: AppFontSize.sm,
                    fontWeight: AppWeight.semiBold,
                  ),
                ),
                child: busy
                    ? const SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      )
                    : const Text('提交'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
