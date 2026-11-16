import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/dev_auto_connect.dart';
import '../../core/session.dart';
import '../pairing/pairing_page.dart';

/// 开发模式自动配对的进度。
enum DevAutoPairPhase { idle, running, failed }

class DevAutoPairState {
  const DevAutoPairState({this.phase = DevAutoPairPhase.idle, this.message = ''});

  final DevAutoPairPhase phase;

  /// 失败原因（给人看的），成功后清空。
  final String message;
}

final NotifierProvider<DevAutoPairController, DevAutoPairState>
devAutoPairProvider =
    NotifierProvider<DevAutoPairController, DevAutoPairState>(
      DevAutoPairController.new,
    );

/// 只负责"跑一次自动配对 + 记住结果"。
///
/// 为什么要这层：RootGate 会随 `sessionProvider` 变化重建，而自动配对本身会产生
/// 好几次 session 变更；不在这里做一次性保护就会反复提交配对码（服务端只允许
/// 一张活跃票据，第二次必然 409，界面还会来回闪）。
class DevAutoPairController extends Notifier<DevAutoPairState> {
  bool _attempted = false;

  @override
  DevAutoPairState build() => const DevAutoPairState();

  Future<void> run() async {
    if (!DevAutoConnect.enabled || _attempted) {
      return;
    }
    _attempted = true;
    state = const DevAutoPairState(
      phase: DevAutoPairPhase.running,
      message: '正在用开发参数连接服务…',
    );

    String? error;
    try {
      error = await ref
          .read(sessionProvider.notifier)
          .devAutoPair(
            serverUrl: DevAutoConnect.serverUrl,
            code: DevAutoConnect.pairCode,
          );
    } on Object catch (unexpected) {
      // 自动配对是开发便利功能，任何意外都不能把启动流程带崩。
      error = '$unexpected';
    }

    if (error == null) {
      state = const DevAutoPairState();
      return;
    }
    state = DevAutoPairState(
      phase: DevAutoPairPhase.failed,
      message: error,
    );
  }

  /// 失败后的手动重试：清掉一次性标记，允许再跑一轮。
  Future<void> retry() async {
    _attempted = false;
    await run();
  }
}

/// 自动配对过渡页 / 失败页。
///
/// 地址与码都由 `./scripts/dev.sh client` 通过 dart-define 注入，用户不需要输入任何东西；
/// 失败时保留"手动配对"这条退路（会带上已注入的地址与码，少填两项）。
class DevAutoPairGate extends ConsumerStatefulWidget {
  const DevAutoPairGate({super.key});

  @override
  ConsumerState<DevAutoPairGate> createState() => _DevAutoPairGateState();
}

class _DevAutoPairGateState extends ConsumerState<DevAutoPairGate> {
  bool _manual = false;

  @override
  void initState() {
    super.initState();
    // build 期间不能写 provider：挪到下一个 microtask 再启动。
    Future<void>.microtask(() => ref.read(devAutoPairProvider.notifier).run());
  }

  @override
  Widget build(BuildContext context) {
    if (_manual) {
      return PairingPage(
        initialServerUrl: DevAutoConnect.serverUrl,
        initialCode: DevAutoConnect.pairCode,
      );
    }

    final state = ref.watch(devAutoPairProvider);
    final pairing = ref.watch(pairingProvider);
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final failed = state.phase == DevAutoPairPhase.failed;

    // 配对进入轮询阶段后，用配对控制器的话术（"等待本机确认…"）更准确。
    final message = failed
        ? state.message
        : (pairing.isBusy ? pairing.message : state.message);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (failed)
                    Icon(Icons.error_outline, size: 40, color: scheme.error)
                  else
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    failed ? '自动配对失败' : '正在用开发参数配对',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontSize: AppFontSize.display,
                      color: palette.text.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: AppFontSize.base,
                      color: palette.text.secondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    DevAutoConnect.serverUrl,
                    textAlign: TextAlign.center,
                    style: AppText.of(context).mono(
                      size: AppFontSize.sm,
                      height: AppLineHeight.tight,
                      color: palette.text.secondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (failed)
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton(
                          onPressed: () => ref
                              .read(devAutoPairProvider.notifier)
                              .retry(),
                          child: const Text('重试'),
                        ),
                        OutlinedButton(
                          onPressed: () => setState(() => _manual = true),
                          child: const Text('手动配对'),
                        ),
                      ],
                    )
                  else
                    Text(
                      '本机确认由 ./scripts/dev.sh 代劳，通常几秒内完成',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: AppFontSize.sm,
                        color: palette.text.secondary,
                      ),
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
