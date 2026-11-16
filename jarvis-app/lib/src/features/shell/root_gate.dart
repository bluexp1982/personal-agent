import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/dev_auto_connect.dart';
import '../../core/session.dart';
import '../pairing/pairing_page.dart';
import '../recordings/recording_navigation.dart';
import 'dev_auto_pair_gate.dart';
import 'home_shell.dart';

/// 启动门：未配对 → 配对页；已配对但登录失败 → 重连页；就绪 → 主界面。
class RootGate extends ConsumerWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    return session.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => _RetryScaffold(
        title: '启动失败',
        message: '$error',
        onRetry: () => ref.invalidate(sessionProvider),
      ),
      data: (state) {
        // 开发模式（`dev.sh client` 注入了地址与配对码）：连不上就用注入的参数
        // 自动配对，未配对和登录失败都算"连不上"。成功后会带着令牌重建，跳过这里。
        if (DevAutoConnect.enabled && !state.hasToken) {
          return const DevAutoPairGate();
        }
        if (!state.isPaired) {
          return PairingPage(initialServerUrl: state.serverUrl);
        }
        if (!state.hasToken) {
          return _RetryScaffold(
            title: '无法登录',
            message: state.error ?? '登录凭据已失效',
            onRetry: () => ref.read(sessionProvider.notifier).retryLogin(),
            onForget: () => ref.read(sessionProvider.notifier).forgetDevice(),
          );
        }
        // 包一层引导：录音账本只在进程启动时恢复一次，
        // 不放进 HomeShell.build（那里会被频繁重建）。
        return RecordingBootstrap(child: HomeShell(session: state));
      },
    );
  }
}

class _RetryScaffold extends StatelessWidget {
  const _RetryScaffold({
    required this.title,
    required this.message,
    required this.onRetry,
    this.onForget,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          // 长错误信息 + 小屏（尤其横屏手机）会纵向溢出，因此可滚动并留边距。
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.link_off, size: 40, color: scheme.error),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: AppFontSize.display,
                      color: AppPalette.of(context).text.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: AppFontSize.base,
                      color: AppPalette.of(context).text.secondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton(onPressed: onRetry, child: const Text('重试')),
                      if (onForget != null)
                        OutlinedButton(
                          onPressed: onForget,
                          child: const Text('解除配对'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
