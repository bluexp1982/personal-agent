import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/browser/browser_models.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';

/// 空态：与参考图同一句提示，不额外堆引导卡片。
class BrowserEmptyView extends StatelessWidget {
  const BrowserEmptyView({super.key, required this.onPickDirectory});

  final VoidCallback onPickDirectory;

  /// 手机端没有"浏览本机目录"这回事：只开放桌面端的目录入口。
  static bool get supportsDirectory =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '输入 HTTP(S) 地址开始浏览',
            style: AppText.of(context).row.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (supportsDirectory) ...<Widget>[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: onPickDirectory,
              icon: const Icon(Icons.folder_open_rounded, size: 15),
              label: const Text(
                '打开本地目录…',
                style: TextStyle(fontSize: AppFontSize.sm),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: scheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 失败卡：给出可执行的下一步，而不是一句"网络错误"。
class BrowserErrorView extends StatelessWidget {
  const BrowserErrorView({
    super.key,
    required this.failure,
    this.onRetry,
    this.onSwitchToServer,
    this.onOpenExternal,
  });

  final BrowserFailure failure;
  final VoidCallback? onRetry;
  final VoidCallback? onSwitchToServer;
  final VoidCallback? onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.error_outline_rounded,
                size: 26,
                color: scheme.error.withValues(alpha: 0.8),
              ),
              const SizedBox(height: 8),
              Text(
                failure.hint,
                textAlign: TextAlign.center,
                style: AppText.of(context).hint.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  if (onRetry != null)
                    TextButton(
                      onPressed: onRetry,
                      child: const Text(
                        '重试',
                        style: TextStyle(fontSize: AppFontSize.sm),
                      ),
                    ),
                  if (onSwitchToServer != null)
                    TextButton(
                      onPressed: onSwitchToServer,
                      child: const Text(
                        '改从服务器打开',
                        style: TextStyle(fontSize: AppFontSize.sm),
                      ),
                    ),
                  if (onOpenExternal != null)
                    TextButton(
                      onPressed: onOpenExternal,
                      child: const Text(
                        '在系统浏览器打开',
                        style: TextStyle(fontSize: AppFontSize.sm),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
