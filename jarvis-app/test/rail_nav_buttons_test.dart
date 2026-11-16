import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/window_chrome.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

const Project _w1 = Project(
  id: 'w1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/hello-demo',
);

const Project _w2 = Project(
  id: 'w2',
  name: '周报整理',
  mode: ProjectModes.work,
  path: '/tmp/weekly',
);

/// 空服务端：导航按钮不出网，骨架只需要能渲染。
Widget _harness() {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(null)],
    child: const MaterialApp(home: HomeShell(session: _session)),
  );
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _collapseRail(WidgetTester tester) async {
  await tester.tap(find.byKey(kRailToggleKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('左栏展开：红绿灯 → 开合 → 后退 → 前进', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurface(tester, const Size(1200, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final toggle = tester.getRect(find.byKey(kRailToggleKey));
      final back = tester.getRect(find.byKey(kRailBackKey));
      final forward = tester.getRect(find.byKey(kRailForwardKey));

      expect(
        toggle.left,
        greaterThanOrEqualTo(kMacWindowButtonsWidth),
        reason: '开合按钮要落在红绿灯后面',
      );
      expect(back.left, greaterThanOrEqualTo(toggle.right), reason: '后退紧跟开合');
      expect(forward.left, greaterThanOrEqualTo(back.right), reason: '前进在后退右侧');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('收起左栏：后退/前进跟到中栏，排在新建会话之前', (tester) async {
    await _setSurface(tester, const Size(1280, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await _collapseRail(tester);

    expect(
      find.byKey(kRailBackKey),
      findsOneWidget,
      reason: '同一时刻只有一份，不会和左栏那份重复',
    );
    expect(find.byKey(kRailForwardKey), findsOneWidget);

    final toggle = tester.getRect(find.byKey(kRailToggleKey));
    final back = tester.getRect(find.byKey(kRailBackKey));
    final forward = tester.getRect(find.byKey(kRailForwardKey));
    final newConversation = tester.getRect(find.byKey(kNewConversationKey));

    expect(back.left, greaterThanOrEqualTo(toggle.right), reason: '后退在「显示左栏」后面');
    expect(forward.left, greaterThanOrEqualTo(back.right), reason: '前进在后退右侧');
    expect(
      newConversation.left,
      greaterThanOrEqualTo(forward.right),
      reason: '新建会话排在导航按钮之后',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有历史时两枚按钮都不可点，点了也不弹提示', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byTooltip('后退'), findsOneWidget);
    expect(find.byTooltip('前进'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(kRailBackKey)).onPressed,
      isNull,
      reason: '还没打开过任何页面，没有可退的地方',
    );
    expect(
      tester.widget<IconButton>(find.byKey(kRailForwardKey)).onPressed,
      isNull,
    );

    await tester.tap(find.byKey(kRailBackKey));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing, reason: '不可用不是错误，不该弹提示条');
    expect(tester.takeException(), isNull);
  });

  testWidgets('后退 / 前进真正切换中栏页面', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final container = _container(tester);
    final targets = container.read(shellTargetProvider.notifier);

    targets.select(const ProjectTarget(_w1));
    await tester.pumpAndSettle();
    expect(container.read(shellTargetProvider), const ProjectTarget(_w1));
    expect(
      tester.widget<IconButton>(find.byKey(kRailBackKey)).onPressed,
      isNotNull,
      reason: '打开过一页之后就能退回去',
    );
    expect(
      tester.widget<IconButton>(find.byKey(kRailForwardKey)).onPressed,
      isNull,
      reason: '还没退过，没有可前进的地方',
    );

    targets.select(const ProjectTarget(_w2));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kRailBackKey));
    await tester.pumpAndSettle();
    expect(
      container.read(shellTargetProvider),
      const ProjectTarget(_w1),
      reason: '后退回到上一页',
    );
    expect(
      tester.widget<IconButton>(find.byKey(kRailForwardKey)).onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(kRailForwardKey));
    await tester.pumpAndSettle();
    expect(
      container.read(shellTargetProvider),
      const ProjectTarget(_w2),
      reason: '前进回到后退前的那一页',
    );

    // 后退之后另选一页：前进方向作废，按钮跟着灰回去。
    await tester.tap(find.byKey(kRailBackKey));
    await tester.pumpAndSettle();
    targets.select(const ProjectTarget(_w2));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(kRailForwardKey)).onPressed,
      isNull,
      reason: '从这里分叉之后不再有"往前"',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('栏宽拖到下限 260 时这一行仍不溢出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurface(tester, const Size(1200, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(kRailResizeHandleKey)),
      );
      // 300 → 260：正好停在下限，不触发蓄力收起。
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(RailNavigator)).width,
        closeTo(kRailMinWidth, 1),
      );
      expect(find.byKey(kRailForwardKey), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '最窄栏宽下栏头不应溢出');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
