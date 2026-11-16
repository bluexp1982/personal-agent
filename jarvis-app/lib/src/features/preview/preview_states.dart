import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../shell/shell_layout_state.dart';

/// 预览区的加载态。
///
/// 收成公共组件是因为图片、PDF、全屏页三处都要它：各写一份时
/// 圈的大小、颜色会在三轮改动后各不相同。
class PreviewLoading extends StatelessWidget {
  const PreviewLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

/// 中性提示（没有可预览的文件、格式不支持等）。
class PreviewHint extends StatelessWidget {
  const PreviewHint(this.text, {super.key, this.action});

  final String text;

  /// 提示下方的动作，例如「另存为」。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kPaneContentInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                color: AppPalette.of(context).text.tertiary,
                height: AppLineHeight.relaxed,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 10),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 文件被服务端截断时的提示条。
///
/// 文本与 Markdown 两个查看器共用：文案与配色只该有一份，
/// 否则同一个 512 KB 上限在两处会出现两种说法。
class PreviewTruncatedBanner extends StatelessWidget {
  const PreviewTruncatedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      color: scheme.tertiaryContainer.withValues(alpha: 0.5),
      child: Text(
        '文件较大，仅显示前一部分',
        style: TextStyle(
          fontSize: AppFontSize.xs,
          color: scheme.onTertiaryContainer,
        ),
      ),
    );
  }
}

/// 预览失败：可读原因 + 手动重试。
///
/// 不自动重试：越界、权限、二进制、文件被删都是确定性失败，
/// 自动重试只会让界面一直转圈，用户还以为在加载。
class PreviewErrorCard extends StatelessWidget {
  const PreviewErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kPaneContentInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.insert_drive_file_outlined,
              size: 26,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
                height: AppLineHeight.relaxed,
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
