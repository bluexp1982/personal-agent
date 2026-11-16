import 'package:jarvis_app/src/core/ssh/ssh_controller.dart';
import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:jarvis_app/src/features/ssh/ssh_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 已连接但没有真实连接的控制器：断开是纯状态动作，测试不需要网络与钥匙串。
///
/// 继承真的 `SshController` 而不是打桩，是为了让 `disconnect()` 走真正实现
/// （本次改的就是它）：没有连接时 `_release()` 是空操作，状态照样落到位。
class _ConnectedSshController extends SshController {
  @override
  SshState build() => const SshState(
    phase: SshPhase.connected,
    username: 'tester',
    target: '127.0.0.1:22',
    tunnelEnabled: true,
    sshdReachable: true,
  );

  @override
  Future<SshSavedCredentials> loadSaved() async => const SshSavedCredentials();

  @override
  Future<SshAutoLoginPlan> loadAutoLoginPlan() async => const SshAutoLoginPlan(
    credentials: SshSavedCredentials(),
    autoLogin: false,
    canAutoLogin: false,
  );

  @override
  Future<void> probe() async {}
}

Widget _harness() {
  return ProviderScope(
    overrides: [
      sshControllerProvider.overrideWith(_ConnectedSshController.new),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SshPage(allowFullscreen: false)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点断开：停在终端页的已断开态，输出留在原地', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.text('连接已断开'), findsNothing);

    await tester.tap(find.byTooltip('断开'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SshPage)),
    );
    final state = container.read(sshControllerProvider);
    expect(state.phase, SshPhase.disconnected, reason: '与远端 exit 同一个状态');
    expect(state.failure, isNull, reason: '主动断开不是故障');
    expect(state.message, isNull, reason: '不该挂一句红字');

    // 仍是终端页：标签栏、状态栏、输出都还在，中央浮出断线遮罩。
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.text('连接服务器'), findsNothing, reason: '不该退回连接表单');
    expect(find.text('连接已断开'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(find.textContaining('已断开'), findsWidgets, reason: '状态栏也要写着已断开');
    // 截图里那五颗动作按钮都还在（全屏按钮这里没开，只有四颗）。
    for (final tooltip in <String>['重连', '断开', '复制选中', '粘贴']) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('已断开时再点断开是幂等的，界面不变', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('断开'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('断开'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SshPage)),
    );
    expect(container.read(sshControllerProvider).phase, SshPhase.disconnected);
    expect(find.text('连接已断开'), findsOneWidget);
    expect(find.text('连接服务器'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
