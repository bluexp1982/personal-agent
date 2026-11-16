import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ssh/ssh_controller.dart';
import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/panel_fullscreen.dart';
import 'package:jarvis_app/src/features/shell/panel_start_view.dart';
import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:jarvis_app/src/features/shell/immersive_fullscreen.dart';
import 'package:jarvis_app/src/features/shell/immersive_fullscreen_hint.dart';
import 'package:jarvis_app/src/features/shell/project_panel.dart';
import 'package:jarvis_app/src/features/ssh/ssh_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 已连接但没有任何真实连接的控制器：全屏是纯视图状态，测试不需要网络与钥匙串。
class _ConnectedSshController extends SshController {
  @override
  SshState build() => _connected;

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

const SshState _connected = SshState(
  phase: SshPhase.connected,
  username: 'tester',
  target: '127.0.0.1:22',
  tunnelEnabled: true,
  sshdReachable: true,
);

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

/// 原生窗口通道的替身。
///
/// 记录 Flutter 请求过的目标状态，同时模拟"窗口现在是不是全屏"，
/// 好断言"进入前已经是全屏时，退出不能再把窗口还原"。
class _WindowChannelLog {
  bool nativeFullScreen = false;
  final List<bool> setCalls = <bool>[];
}

const MethodChannel _windowChannel = MethodChannel('personal_agent/window');

void _mockWindowChannel(_WindowChannelLog log) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_windowChannel, (MethodCall call) async {
    switch (call.method) {
      case 'isFullScreen':
        return log.nativeFullScreen;
      case 'setFullScreen':
        final arguments = call.arguments as Map<Object?, Object?>;
        final target = arguments['fullScreen'] as bool;
        log.setCalls.add(target);
        log.nativeFullScreen = target;
        return null;
      default:
        return null;
    }
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_windowChannel, null));
}

/// 让原生通道上的 `invokeMethod` / `setMethodCallHandler` 有地方落。
void _useMacOSPlatform() {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

/// 模拟原生侧主动通知"窗口已经不是全屏了"（macOS 点绿灯 / Ctrl+Cmd+F）。
Future<void> _emitNativeFullScreen(bool fullScreen) async {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall('fullScreenChanged', <String, Object>{'fullScreen': fullScreen}),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('personal_agent/window', data, (_) {});
  await pumpEventQueue();
}

Widget _harness() {
  return ProviderScope(
    overrides: [
      sshControllerProvider.overrideWith(_ConnectedSshController.new),
    ],
    child: MaterialApp(home: HomeShell(session: _session)),
  );
}

Future<ProviderContainer> _openTerminal(
  WidgetTester tester, {
  Size size = const Size(1200, 800),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle();

  final container = ProviderScope.containerOf(
    tester.element(find.byType(HomeShell)),
  );

  await tester.tap(find.byKey(kFilePaneToggleKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(kPanelStartTerminalCardKey));
  await tester.pumpAndSettle();

  return container;
}

/// 走终端自己的按键通道按 Esc，返回它是否被消费。
KeyEventResult _pressEsc(WidgetTester tester) {
  final view = tester.widget<TerminalView>(find.byType(TerminalView));
  final onKeyEvent = view.onKeyEvent;
  expect(onKeyEvent, isNotNull);
  return onKeyEvent!(
    FocusNode(),
    const KeyDownEvent(
      timeStamp: Duration.zero,
      logicalKey: LogicalKeyboardKey.escape,
      physicalKey: PhysicalKeyboardKey.escape,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('immersiveFullscreenProvider', () {
    test('进入时窗口不在全屏：请求原生全屏，退出时还原', () async {
      _useMacOSPlatform();
      final log = _WindowChannelLog();
      _mockWindowChannel(log);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(immersiveFullscreenProvider.notifier);

      expect(container.read(immersiveFullscreenProvider), isNull);

      await controller.enter(ImmersiveSurface.panel);
      expect(
        container.read(immersiveFullscreenProvider),
        ImmersiveSurface.panel,
      );
      expect(log.setCalls, <bool>[true], reason: '要真的把窗口推进全屏');

      controller.exit();
      expect(container.read(immersiveFullscreenProvider), isNull);
      await pumpEventQueue();
      expect(log.setCalls, <bool>[true, false], reason: '退出后恢复普通窗口');
    });

    test('进入前窗口已经是全屏：退出保持全屏，不再回调原生', () async {
      _useMacOSPlatform();
      final log = _WindowChannelLog()..nativeFullScreen = true;
      _mockWindowChannel(log);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(immersiveFullscreenProvider.notifier);

      await controller.enter(ImmersiveSurface.panel);
      expect(log.setCalls, isEmpty, reason: '窗口本来就在全屏，无需再切');

      controller.exit();
      await pumpEventQueue();
      expect(log.setCalls, isEmpty, reason: '退出只还原界面，窗口保持原样');
      expect(container.read(immersiveFullscreenProvider), isNull);
    });

    test('原生侧退出全屏时界面跟着退出，且不回环调用原生', () async {
      _useMacOSPlatform();
      final log = _WindowChannelLog();
      _mockWindowChannel(log);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(immersiveFullscreenProvider.notifier);

      await controller.enter(ImmersiveSurface.panel);
      expect(
        container.read(immersiveFullscreenProvider),
        ImmersiveSurface.panel,
      );

      await _emitNativeFullScreen(false);
      expect(
        container.read(immersiveFullscreenProvider),
        isNull,
        reason: '用户从系统侧退出全屏，界面不能还停在满屏终端',
      );
      expect(log.setCalls, <bool>[true], reason: '系统已经退出了，不能再调一次');
    });

    test('进入后立刻退出：过期的异步结果不会把窗口留在全屏', () async {
      _useMacOSPlatform();
      final log = _WindowChannelLog();
      _mockWindowChannel(log);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(immersiveFullscreenProvider.notifier);

      // 不 await：模拟"按下按钮立刻按 Esc"。
      final entering = controller.enter(ImmersiveSurface.panel);
      controller.exit();
      await entering;
      await pumpEventQueue();

      expect(container.read(immersiveFullscreenProvider), isNull);
      expect(
        log.nativeFullScreen,
        isFalse,
        reason: '无论中间经历几次切换，最终必须回到进入前的窗口状态',
      );
    });
  });

  testWidgets('终端全屏：左栏、标签栏、状态栏全部让位，只剩终端', (tester) async {
    final container = await _openTerminal(tester);

    await tester.tap(find.byKey(kTerminalFullscreenKey));
    await tester.pumpAndSettle();

    expect(
      container.read(immersiveFullscreenProvider),
      ImmersiveSurface.panel,
    );
    expect(
      container.read(panelFullscreenProvider),
      isFalse,
      reason: '两套全屏各管各的，终端全屏不该改写面板全屏',
    );

    // 其它内容全部消失：左栏、标签栏、终端自己的状态栏。
    expect(find.byType(RailNavigator), findsNothing);
    expect(find.byKey(kFilePaneFullscreenKey), findsNothing);
    expect(find.byKey(kTerminalFullscreenKey), findsNothing);
    expect(find.byTooltip('重连'), findsNothing);
    expect(find.byKey(kShellEmptyChatKey), findsNothing);

    // 终端铺满整块窗口。
    expect(find.byType(TerminalView), findsOneWidget);
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(1200, 1),
      reason: '左栏也让位，面板拿到整个窗口宽度',
    );
    expect(
      tester.getSize(find.byType(TerminalView)).height,
      greaterThan(700),
      reason: '状态栏也藏了，终端要吃掉它那 40dp',
    );

    // 进入时的一次性提示。
    expect(find.text(kImmersiveFullscreenHintText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esc 退出终端全屏并恢复进入前的布局', (tester) async {
    final container = await _openTerminal(tester);

    await tester.tap(find.byKey(kTerminalFullscreenKey));
    await tester.pumpAndSettle();
    expect(
      container.read(immersiveFullscreenProvider),
      ImmersiveSurface.panel,
    );

    expect(_pressEsc(tester), KeyEventResult.handled);
    await tester.pumpAndSettle();

    expect(container.read(immersiveFullscreenProvider), isNull);
    expect(find.byType(RailNavigator), findsOneWidget, reason: '左栏回来');
    expect(find.byKey(kTerminalFullscreenKey), findsOneWidget, reason: '状态栏回来');
    expect(find.byKey(kFilePaneFullscreenKey), findsOneWidget, reason: '标签栏回来');
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(kFilePaneWidth, 1),
      reason: '面板回到用户拖出来的宽度',
    );
  });

  testWidgets('全屏下收起面板会退出终端全屏', (tester) async {
    final container = await _openTerminal(tester);

    await tester.tap(find.byKey(kTerminalFullscreenKey));
    await tester.pumpAndSettle();
    expect(
      container.read(immersiveFullscreenProvider),
      ImmersiveSurface.panel,
    );

    // 沉浸模式里没有隐藏按钮，模拟"面板自己被收起"的另一条路径。
    container.read(filePaneVisibleProvider.notifier).hide();
    await tester.pumpAndSettle();

    expect(
      container.read(immersiveFullscreenProvider),
      isNull,
      reason: '面板没了，留下一个满屏标记只会让下次打开时直接全屏',
    );
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
  });

  testWidgets('切到别的标签会退出终端全屏', (tester) async {
    final container = await _openTerminal(tester);

    await tester.tap(find.byKey(kTerminalFullscreenKey));
    await tester.pumpAndSettle();
    expect(
      container.read(immersiveFullscreenProvider),
      ImmersiveSurface.panel,
    );

    // 沉浸模式里标签栏是藏起来的，走状态层模拟"标签被切走"的另一条路径。
    container.read(filePaneTabProvider.notifier).openFiles();
    await tester.pumpAndSettle();

    expect(container.read(immersiveFullscreenProvider), isNull);
    expect(find.byKey(kFilePaneFullscreenKey), findsOneWidget, reason: '标签栏回来');
  });
}
