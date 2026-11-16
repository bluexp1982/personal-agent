import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ssh/ssh_controller.dart';
import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:jarvis_app/src/core/window_chrome.dart';
import 'package:jarvis_app/src/features/shell/chat_window_state.dart';
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
///
/// `loadSaved` / `probe` 一并置空，否则进入终端会去读钥匙串、探测隧道。
class _ConnectedSshController extends SshController {
  _ConnectedSshController(this._initial);

  final SshState _initial;

  @override
  SshState build() => _initial;

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

  /// 模拟"连接掉线后回到表单"之外的另一条路径：主动断开。
  void simulateIdle() => state = state.copyWith(phase: SshPhase.idle);
}

/// 未连接的控制器替身：复现"第一次在全屏下打开终端"的路径。
class _IdleSshController extends SshController {
  @override
  SshState build() => const SshState.initial();

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

  @override
  Future<void> disconnect() async {}
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

/// 状态栏里的动作必须是图标按钮（`IconButton` 的 tooltip 会包一层 `Tooltip`），
/// 不能退回文字按钮：这一行在 360dp 下放不下第二个两字按钮。
///
/// 同时锁住栏头规格：命中区 [kPaneHeaderButtonSize] 见方、图标
/// [kPaneHeaderIconSize]。少了这两条，后加按钮又会按所在行高另开一套尺寸。
void _expectIconAction(WidgetTester tester, Finder tooltipFinder) {
  expect(tooltipFinder, findsOneWidget);

  final iconFinder = find.descendant(
    of: tooltipFinder,
    matching: find.byType(Icon),
  );
  expect(iconFinder, findsOneWidget);
  // `IconButton` 的 `iconSize` 是通过 `IconTheme` 生效的，`Icon.size` 仍是 null；
  // 要量渲染尺寸，不能读 widget 字段。
  expect(tester.getSize(iconFinder), const Size.square(kPaneHeaderIconSize));

  // 图标色跟项目页那排图标一致：灰色（onSurfaceVariant），不是终端 tint。
  // `IconButton.color` 同样走 `IconTheme`，`Icon.color` 是 null，要读主题。
  final iconContext = tester.element(iconFinder);
  expect(
    IconTheme.of(iconContext).color,
    Theme.of(iconContext).colorScheme.onSurfaceVariant,
  );

  final buttonFinder = find.ancestor(
    of: tooltipFinder,
    matching: find.byType(IconButton),
  );
  expect(buttonFinder, findsOneWidget);
  expect(
    tester.getSize(buttonFinder),
    const Size.square(kPaneHeaderButtonSize),
    reason: '终端状态栏按钮要与栏头同一套命中区',
  );
}

Widget _harness() {
  return ProviderScope(
    overrides: [
      sshControllerProvider.overrideWith(
        () => _ConnectedSshController(_connected),
      ),
    ],
    child: MaterialApp(home: HomeShell(session: _session)),
  );
}

/// 未配对的终端：进面板点「新建终端」先看到连接表单。
Widget _idleHarness() {
  return ProviderScope(
    overrides: [sshControllerProvider.overrideWith(_IdleSshController.new)],
    child: MaterialApp(home: HomeShell(session: _session)),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 从右侧面板打开终端，并停在已连接状态。
Future<ProviderContainer> _openTerminal(
  WidgetTester tester, {
  Size size = const Size(1200, 800),
}) async {
  await _setSurface(tester, size);
  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle();

  // 容器要在推面板之前取：窄屏的整页面板是一层不透明路由，
  // 底下的 `HomeShell` 被挡住后就不再出现在 widget 树里，取不到 Element。
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HomeShell)),
  );

  // 宽屏从右栏开关进面板；窄屏从顶栏的面板入口进（整页）。
  if (size.width >= kShellBreakpoint) {
    await tester.tap(find.byKey(kFilePaneToggleKey));
  } else {
    await tester.tap(find.byKey(kPanelEntryKey));
  }
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(kPanelStartTerminalCardKey));
  await tester.pumpAndSettle();

  return container;
}

/// 非全屏时不应吞掉 Esc：返回 ignored，远端程序照旧收到。
KeyEventResult _pressEsc(WidgetTester tester) {
  final view = tester.widget<TerminalView>(find.byType(TerminalView));
  final onKeyEvent = view.onKeyEvent;
  expect(onKeyEvent, isNotNull, reason: 'Esc 拦截必须挂在 TerminalView.onKeyEvent 上');
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

  group('panelFullscreenProvider', () {
    test('toggle 往返，exit 幂等', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(panelFullscreenProvider.notifier);

      expect(
        container.read(panelFullscreenProvider),
        isFalse,
        reason: '默认是常规布局',
      );

      controller.toggle();
      expect(container.read(panelFullscreenProvider), isTrue);

      controller.toggle();
      expect(container.read(panelFullscreenProvider), isFalse);

      controller.exit();
      expect(
        container.read(panelFullscreenProvider),
        isFalse,
        reason: '未全屏时 exit 不应报错',
      );
    });
  });

  testWidgets('点工具条全屏按钮：中栏让位、左侧栏保留、面板铺满', (tester) async {
    final container = await _openTerminal(tester);

    expect(find.byType(RailNavigator), findsOneWidget);
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(kFilePaneWidth, 1),
    );

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();

    expect(container.read(panelFullscreenProvider), isTrue);
    expect(find.byKey(kShellEmptyChatKey), findsNothing, reason: '全屏要藏掉中间内容区');
    expect(
      find.byType(RailNavigator),
      findsOneWidget,
      reason: '左侧栏保留：全屏看终端时还要能切项目',
    );
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(1200 - kShellRailWidth - kRailHandleWidth, 1),
      reason: '面板应当吃掉「窗口 - 左栏 - 分隔条」整块宽度',
    );
    expect(
      find.byKey(kFilePaneResizeHandleKey),
      findsNothing,
      reason: '没有中间区可让，拖动条也就没有意义',
    );
    expect(find.byTooltip('退出全屏'), findsOneWidget);

    // 状态栏压缩保留：连接信息与三个动作都还在。
    expect(find.textContaining('127.0.0.1:22'), findsOneWidget);
    // 「重连 / 断开」现在是图标按钮：文案只留在 tooltip 上。
    _expectIconAction(tester, find.byTooltip('重连'));
    _expectIconAction(tester, find.byTooltip('断开'));
    expect(find.byType(TerminalView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('终端状态栏的全屏按钮进入终端全屏，不改写工具条的面板全屏', (tester) async {
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
      reason: '两套全屏是并列的，状态不能互相改写',
    );
    expect(find.byKey(kShellEmptyChatKey), findsNothing);
    expect(find.text(kImmersiveFullscreenHintText), findsOneWidget);

    // 沉浸模式下连状态栏与标签栏都不在，两颗全屏按钮同时消失。
    expect(find.byKey(kTerminalFullscreenKey), findsNothing);
    expect(find.byKey(kFilePaneFullscreenKey), findsNothing);

    expect(_pressEsc(tester), KeyEventResult.handled);
    await tester.pumpAndSettle();

    expect(container.read(immersiveFullscreenProvider), isNull);
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
    expect(find.byKey(kTerminalFullscreenKey), findsOneWidget);
  });

  testWidgets('全屏下再点工具条按钮回到三栏', (tester) async {
    final container = await _openTerminal(tester);

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();

    expect(container.read(panelFullscreenProvider), isFalse);
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(kFilePaneWidth, 1),
      reason: '退出全屏后面板回到原来的宽度',
    );
  });

  testWidgets('非全屏时 Esc 透传给远端，全屏时 Esc 退出', (tester) async {
    final container = await _openTerminal(tester);

    expect(
      _pressEsc(tester),
      KeyEventResult.ignored,
      reason: '非全屏的 Esc 必须留给 vim/less',
    );

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();

    expect(_pressEsc(tester), KeyEventResult.handled);
    await tester.pumpAndSettle();
    expect(container.read(panelFullscreenProvider), isFalse);
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
  });

  testWidgets('回到连接表单不退出全屏，标签栏仍提供出口', (tester) async {
    final container = await _openTerminal(tester);

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();
    expect(container.read(panelFullscreenProvider), isTrue);

    (container.read(sshControllerProvider.notifier) as _ConnectedSshController)
        .simulateIdle();
    await tester.pumpAndSettle();

    expect(
      container.read(panelFullscreenProvider),
      isTrue,
      reason: '连接状态变化不该改变面板布局',
    );
    expect(
      find.byKey(kFilePaneFullscreenKey),
      findsOneWidget,
      reason: '标签栏里仍有退出全屏的入口，表单不会被困在满屏里',
    );
    expect(find.byKey(kShellEmptyChatKey), findsNothing);
  });

  testWidgets('全屏下第一次打开终端不会被踢出全屏', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_idleHarness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeShell)),
    );

    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();
    expect(container.read(panelFullscreenProvider), isTrue);

    // 还没连接：点开终端先看到连接表单——这一条路径以前会顺手退出全屏。
    await tester.tap(find.byKey(kPanelStartTerminalCardKey));
    await tester.pumpAndSettle();

    expect(
      container.read(panelFullscreenProvider),
      isTrue,
      reason: '打开终端不该改变面板布局',
    );
    expect(find.byKey(kShellEmptyChatKey), findsNothing);
    expect(find.byKey(kFilePaneFullscreenKey), findsOneWidget);
    expect(find.text('连接服务器'), findsWidgets, reason: '确实停在了连接表单');
  });

  testWidgets('关闭终端标签后仍留在全屏，只是回到相邻标签', (tester) async {
    final container = await _openTerminal(tester);

    // 先补一张空白页当邻居：否则关掉唯一的标签就等于整栏收起，那是另一条语义。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelTerminalTabKey));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();
    expect(container.read(panelFullscreenProvider), isTrue);

    await tester.tap(find.byTooltip('关闭终端标签'));
    await tester.pumpAndSettle();

    expect(
      container.read(panelFullscreenProvider),
      isTrue,
      reason: '全屏属于面板，关掉某个标签不该改变布局',
    );
    expect(find.byKey(kPanelTerminalTabKey), findsNothing);
    expect(
      find.byType(ProjectPanel),
      findsOneWidget,
      reason: '关标签只收起终端，面板本身还开着（停在开始页）',
    );
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(1200 - kShellRailWidth - kRailHandleWidth, 1),
      reason: '面板仍是铺满中栏的宽度',
    );
    expect(find.byKey(kShellEmptyChatKey), findsNothing, reason: '中间内容区还在让位');
  });

  testWidgets('360dp 整页面板里的终端不溢出，也没有全屏按钮', (tester) async {
    await _openTerminal(tester, size: const Size(360, 800));

    // 整页形态已经铺满屏幕，不再提供两处全屏入口。
    expect(find.byKey(kFilePaneFullscreenKey), findsNothing);
    expect(find.byKey(kTerminalFullscreenKey), findsNothing);
    // 重连 / 断开在窄屏也必须是图标按钮：文字按钮在这里会被挤成两行。
    _expectIconAction(tester, find.byTooltip('重连'));
    _expectIconAction(tester, find.byTooltip('断开'));

    // 复制 / 粘贴已经并进状态栏，与上面两枚同一行、同一规格，
    // 不再浮在终端右上角挡住输出。
    _expectIconAction(tester, find.byTooltip('复制选中'));
    _expectIconAction(tester, find.byTooltip('粘贴'));
    expect(
      tester.getCenter(find.byTooltip('复制选中')).dy,
      closeTo(tester.getCenter(find.byTooltip('重连')).dy, 0.5),
      reason: '复制 / 粘贴与重连在同一行',
    );
    expect(
      find.descendant(
        of: find.byType(TerminalView),
        matching: find.byTooltip('复制选中'),
      ),
      findsNothing,
      reason: '复制 / 粘贴挂在状态栏，不该盖在终端输出上',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('macOS 左栏收起 + 面板全屏：标签栏让开红绿灯', (tester) async {
    // 平台覆盖必须在测试体内还原：框架在测试体结束时就会校验它。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurface(tester, const Size(1200, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // 收起左栏：中栏不再占位，全屏的面板会一直铺到窗口左边缘。
      await tester.tap(find.byKey(kRailToggleKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kFilePaneToggleKey));
      await tester.pumpAndSettle();
      // 先点「+」再选终端：左边那张空白页留下来，作为"第一个标签"量让位。
      await tester.tap(find.byKey(kPanelNewTabKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kPanelStartTerminalCardKey).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kFilePaneFullscreenKey));
      await tester.pumpAndSettle();

      final panel = tester.getRect(find.byType(ProjectPanel));
      expect(panel.left, closeTo(0, 1), reason: '左栏收起时面板贴住窗口左边缘');
      expect(panel.width, closeTo(1200, 1), reason: '全屏的面板占据整个窗口宽度');

      expect(
        tester.getRect(find.byKey(kPanelStartTabKey)).left,
        greaterThanOrEqualTo(kMacWindowButtonsWidth),
        reason: '第一个标签必须让开红绿灯，不能被窗口按钮压住',
      );
      expect(
        tester.getRect(find.byKey(kFilePaneHideKey)).right,
        lessThanOrEqualTo(panel.right),
        reason: '让位之后标签与右端按钮仍要装得下，不能溢出',
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS 全屏但左栏展开：标签栏不额外留白', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final container = await _openTerminal(tester);
      await tester.tap(find.byKey(kFilePaneFullscreenKey));
      await tester.pumpAndSettle();

      // 空白页已经被终端原位替换，第一个标签就是终端标签。
      final firstTab = panelTabKey(
        container.read(filePaneTabProvider).tabs.first,
      );
      final panel = tester.getRect(find.byType(ProjectPanel));
      expect(
        panel.left,
        closeTo(kShellRailWidth + kRailHandleWidth, 1),
        reason: '左栏还在，面板左边缘不在窗口边缘',
      );
      expect(
        tester.getRect(find.byKey(firstTab)).left - panel.left,
        // 只剩栏头自身的 4dp 内边距（栏缝的 8dp 已算进面板，视觉到线仍是 12）：
        // 分隔线由左栏右边框承担，面板自己不再画左边框。
        closeTo(kPaneEdgeInset, 0.5),
        reason: '不该为了不存在的重叠白吃掉标签宽度',
      );
      expect(container.read(panelFullscreenProvider), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS 窄屏整页面板：标签栏也让开红绿灯', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      // 窄屏（< kShellBreakpoint）没有右栏，面板由顶栏入口推成整页，
      // 整页从窗口左缘开始——标题条上的红绿灯照样压着第一个标签。
      final container = await _openTerminal(tester, size: const Size(600, 800));

      final firstTab = panelTabKey(
        container.read(filePaneTabProvider).tabs.first,
      );
      final panel = tester.getRect(find.byType(ProjectPanel));
      expect(panel.left, closeTo(0, 1), reason: '整页面板从窗口左缘开始');
      expect(
        tester.getRect(find.byKey(firstTab)).left,
        greaterThanOrEqualTo(kMacWindowButtonsWidth),
        reason: '红绿灯在标题条上，第一个标签必须让开',
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS 聊天浮窗 + 左栏收起：面板贴左边时也让开红绿灯', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurface(tester, const Size(1200, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeShell)),
      );

      // 截图里那种布局：左栏收起、会话缩成浮窗、右栏打开。
      // 中栏被让给右栏（`_WideContent.hideCenter`），面板因此贴到窗口左缘——
      // 没按过"全屏"，但红绿灯照样在这一行的左端。
      await tester.tap(find.byKey(kRailToggleKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kFilePaneToggleKey));
      await tester.pumpAndSettle();
      container.read(chatWindowProvider.notifier).float(
        const ConversationTarget(
          projectId: '',
          conversationId: 'conv_float',
          title: '沙漏',
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final panel = tester.getRect(find.byType(ProjectPanel));
      expect(panel.left, closeTo(0, 1), reason: '中栏让给右栏后面板贴窗口左缘');
      expect(
        tester.getRect(find.byKey(kPanelStartTabKey)).left,
        greaterThanOrEqualTo(kMacWindowButtonsWidth),
        reason: '红绿灯就在这一行左端，第一个标签必须让开',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS 左栏收起但不全屏：标签栏不额外留白', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurface(tester, const Size(1200, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kRailToggleKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kFilePaneToggleKey));
      await tester.pumpAndSettle();

      final panel = tester.getRect(find.byType(ProjectPanel));
      expect(
        panel.left,
        greaterThan(kMacWindowButtonsWidth),
        reason: '非全屏时面板贴在窗口右侧，离红绿灯很远',
      );
      expect(
        tester.getRect(find.byKey(kPanelStartTabKey)).left - panel.left,
        // 只剩栏头自身的 4dp 内边距（栏缝的 8dp 属于面板，视觉到线仍是 12）：
        // 分隔线由拖动条提供，面板不再自己画左边框。
        closeTo(kPaneEdgeInset, 0.5),
        reason: '没有重叠就不留白',
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
