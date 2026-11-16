import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/core/recording/recording_models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/canvas/canvas_demo_page.dart';
import 'package:jarvis_app/src/features/memory/memory_page.dart';
import 'package:jarvis_app/src/features/recordings/recordings_page.dart';
import 'package:jarvis_app/src/features/settings/settings_dialog.dart';
import 'package:jarvis_app/src/features/settings/settings_page.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/narrow_tabs.dart';
import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:jarvis_app/src/features/shell/shell_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

/// 空服务端：左栏入口都不出网，只要骨架能渲染就够。
Widget _harness() {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(null)],
    child: const MaterialApp(home: HomeShell(session: _session)),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 录音列表里有常驻的加载指示器，`pumpAndSettle` 会等不到静止。
Future<void> _pumpPages(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('宽屏点「录音笔记」：中栏原地显示列表，不再整页盖住左栏', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kRailRecordingsKey));
    await _pumpPages(tester);

    final pane = find.byType(ShellPane);
    expect(pane, findsOneWidget);
    expect(
      find.descendant(of: pane, matching: find.byType(RecordingsPage)),
      findsOneWidget,
      reason: '录音列表占的是中栏这一格',
    );
    expect(find.byType(RailNavigator), findsOneWidget, reason: '左栏没有被盖住');
    expect(
      find.descendant(of: pane, matching: find.byType(AppBar)),
      findsNothing,
      reason: '内嵌形态不画第二层 AppBar，栏头是三栏统一的细栏头',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('录音家族的三种页面都让左栏那一行保持选中', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    Text label() => tester.widget<Text>(
      find.descendant(
        of: find.byKey(kRailRecordingsKey),
        matching: find.text('录音笔记'),
      ),
    );

    /// 选中态只由底色表达，字重恒定：取行内那层带装饰的容器颜色。
    ///
    /// 只在内层找：往上会撞到栏底色，那里任何时候都有颜色。
    Color? fill() {
      final containers = tester.widgetList<Container>(
        find.descendant(
          of: find.byKey(kRailRecordingsKey),
          matching: find.byType(Container),
        ),
      );
      for (final container in containers) {
        final decoration = container.decoration;
        if (decoration is BoxDecoration) {
          return decoration.color;
        }
      }
      return null;
    }

    expect(label().style?.fontWeight, AppWeight.regular, reason: '字重不参与选中');
    expect(fill(), isNull, reason: '没打开时没有选中底色');

    await tester.tap(find.byKey(kRailRecordingsKey));
    await _pumpPages(tester);
    expect(label().style?.fontWeight, AppWeight.regular, reason: '选中也不加粗');
    expect(fill(), isNotNull, reason: '进中栏后有选中底色');

    // 录音进行页也属于同一个入口：那一行不该掉回未选中。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ShellPane)),
    );
    container
        .read(shellTargetProvider.notifier)
        .select(const RecordingSessionTarget());
    await _pumpPages(tester);
    expect(fill(), isNotNull);
    expect(label().style?.fontWeight, AppWeight.regular);
    expect(tester.takeException(), isNull);
  });

  testWidgets('账户菜单里的设置弹出浮层，中栏保持原样；记忆仍在中栏打开', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final pane = find.byType(ShellPane);

    await tester.tap(find.byKey(kRailAccountMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kRailAccountSettingsKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kSettingsDialogKey), findsOneWidget);
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget, reason: '中栏没被设置替换');
    expect(find.byType(RailNavigator), findsOneWidget, reason: '左栏仍然在');
    expect(
      find.descendant(of: pane, matching: find.byType(SettingsPage)),
      findsNothing,
      reason: '设置不再是中栏的一页',
    );

    // 关闭按钮收回浮层，中栏仍是原来那一页。
    await tester.tap(find.byKey(kSettingsDialogCloseKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kSettingsDialogKey), findsNothing);
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);

    await tester.tap(find.byKey(kRailAccountMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kRailAccountMemoryKey));
    await _pumpPages(tester);
    expect(
      find.descendant(of: pane, matching: find.byType(MemoryListPage)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏点「无限画布」：中栏原地显示画布页', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kRailCanvasKey));
    await _pumpPages(tester);

    final pane = find.byType(ShellPane);
    expect(pane, findsOneWidget);
    expect(
      find.descendant(of: pane, matching: find.byType(CanvasDemoPage)),
      findsOneWidget,
      reason: '画布占的是中栏这一格',
    );
    expect(find.byType(RailNavigator), findsOneWidget, reason: '左栏没有被盖住');
    expect(
      find.descendant(of: pane, matching: find.byType(AppBar)),
      findsNothing,
      reason: '内嵌形态不画第二层 AppBar',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏没有中栏：无限画布从「我的」进入，仍是整页路由', (tester) async {
    await _setSurface(tester, const Size(600, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 「我的」直接放着记忆与无限画布两个入口，不必再绕进设置。
    await tester.tap(find.byKey(narrowTabKey(NarrowTab.profile)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无限画布'));
    await _pumpPages(tester);

    expect(find.byType(CanvasDemoPage), findsOneWidget);
    expect(find.byType(ShellPane), findsNothing, reason: '窄屏是单列布局');
    // 画布是推上来的整页：手机版页头带自绘返回钮（35dp 玻璃圆钮里的 chevron），
    // 不再是 Material 的 `BackButton`。
    expect(
      find.byTooltip('返回').hitTestable(),
      findsOneWidget,
      reason: '整页形态自带返回',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏没有中栏：录音笔记是底部导航的一个标签，不再推路由', (tester) async {
    await _setSurface(tester, const Size(600, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.recordings)));
    await _pumpPages(tester);

    expect(find.byType(RecordingsPage), findsOneWidget);
    expect(find.byType(ShellPane), findsNothing, reason: '窄屏是单列布局，没有中栏可言');
    // 切换标签不是 push：没有返回按钮，导航条仍在原地。
    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(kBottomNavKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('录音页的目标与历史', () {
    RecordingDetailTarget detail(String clientId) => RecordingDetailTarget(
      local: LocalRecording(
        clientId: clientId,
        title: '会议',
        mode: RecordingMode.realtime,
        startedAt: 0,
      ),
    );

    test('录音三页都算「录音入口」，其余目标不算', () {
      expect(isRecordingPageTarget(const RecordingsTarget()), isTrue);
      expect(isRecordingPageTarget(detail('c1')), isTrue);
      expect(isRecordingPageTarget(const RecordingSessionTarget()), isTrue);
      expect(isRecordingPageTarget(const MemoryTarget()), isFalse);
      expect(isRecordingPageTarget(const CanvasTarget()), isFalse);
      expect(isRecordingPageTarget(null), isFalse);
    });

    test('删除录音后从后退栈里剪掉它的详情页', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final targets = container.read(shellTargetProvider.notifier);

      targets.select(const RecordingsTarget());
      targets.select(detail('c1'));
      // 删除成功后的顺序：先回列表，再剪枝。
      targets.select(const RecordingsTarget());
      targets.forgetRecording('c1');

      expect(container.read(shellTargetProvider), const RecordingsTarget());

      // 退回去只应停在列表 / 空态，绝不会落到那条已经删掉的录音上。
      while (targets.goBack()) {
        expect(
          container.read(shellTargetProvider),
          isNot(isA<RecordingDetailTarget>()),
        );
      }
    });

    test('同一容器的两次轮询给出等价的详情目标', () {
      expect(detail('c1'), detail('c1'));
      expect(detail('c1'), isNot(detail('c2')));
    });
  });
}
