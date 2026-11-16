import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/canvas/canvas_control_bar.dart';
import 'package:jarvis_app/src/features/canvas/canvas_demo_page.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/immersive_fullscreen.dart';
import 'package:jarvis_app/src/features/shell/immersive_fullscreen_hint.dart';
import 'package:jarvis_app/src/features/shell/project_panel.dart';
import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

Widget _harness() {
  return ProviderScope(
    child: MaterialApp(home: HomeShell(session: _session)),
  );
}

/// 画布页有常驻的连线动效（无限循环 Ticker），`pumpAndSettle` 等不到静止：
/// 打开画布之后一律用固定 pump。
Future<void> _pumpCanvas(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 宽屏打开画布，返回 ProviderContainer。
Future<ProviderContainer> _openCanvas(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle();

  final container = ProviderScope.containerOf(
    tester.element(find.byType(HomeShell)),
  );

  await tester.tap(find.byKey(kRailCanvasKey));
  await _pumpCanvas(tester);

  return container;
}

Future<void> _enterFullscreen(WidgetTester tester) async {
  await tester.tap(find.byKey(kCanvasFullscreenKey));
  await _pumpCanvas(tester);
}

void main() {
  testWidgets('画布全屏：左栏与右栏一起让位，画布铺满整窗', (tester) async {
    final container = await _openCanvas(tester);

    // 右栏默认是收起的：先显式打开，才测得到"全屏时它让位、退出后回来"。
    container.read(filePaneVisibleProvider.notifier).show();
    await _pumpCanvas(tester);

    expect(find.byType(RailNavigator), findsOneWidget);
    expect(find.byType(ProjectPanel), findsOneWidget);

    await _enterFullscreen(tester);

    expect(
      container.read(immersiveFullscreenProvider),
      ImmersiveSurface.canvas,
      reason: '与终端、图片预览同一套沉浸模式，只是宿主换成中栏',
    );
    expect(find.byType(RailNavigator), findsNothing, reason: '左栏让位');
    expect(find.byType(ProjectPanel), findsNothing, reason: '右栏让位');
    expect(find.byType(CanvasControlBar), findsNothing, reason: '画布页自己的控制条也收起');
    expect(
      container.read(filePaneVisibleProvider),
      isTrue,
      reason: '右栏只是不渲染，显隐状态不能被改写：退出后要原样回来',
    );

    expect(
      tester.getSize(find.byKey(kCanvasEditorKey)).width,
      closeTo(1200, 1),
      reason: '画布拿到整个窗口宽度',
    );
    expect(find.text(kImmersiveFullscreenHintText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esc 退出画布全屏并恢复进入前的布局', (tester) async {
    final container = await _openCanvas(tester);
    container.read(filePaneVisibleProvider.notifier).show();
    await _pumpCanvas(tester);

    await _enterFullscreen(tester);
    expect(container.read(immersiveFullscreenProvider), ImmersiveSurface.canvas);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpCanvas(tester);

    expect(container.read(immersiveFullscreenProvider), isNull);
    expect(find.byType(RailNavigator), findsOneWidget, reason: '左栏回来');
    expect(find.byType(ProjectPanel), findsOneWidget, reason: '右栏回来');
    expect(find.byType(CanvasControlBar), findsOneWidget, reason: '控制条回来');
    expect(
      tester.getSize(find.byKey(kCanvasEditorKey)).width,
      lessThan(1200),
      reason: '画布回到中栏那一格',
    );
  });

  testWidgets('点过画布、编辑器拿到焦点之后 Esc 仍然能退出', (tester) async {
    final container = await _openCanvas(tester);
    await _enterFullscreen(tester);
    expect(container.read(immersiveFullscreenProvider), ImmersiveSurface.canvas);

    // 画布库把 Esc 绑成 `cancel_operation`：编辑器自己拿到焦点后，按键会在
    // 它那一层被吃掉。这里点一下画布复现"焦点跑到编辑器里"，再按 Esc。
    await tester.tap(find.byKey(kCanvasEditorKey));
    await _pumpCanvas(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpCanvas(tester);

    expect(
      container.read(immersiveFullscreenProvider),
      isNull,
      reason: 'Esc 不能依赖焦点落在哪儿：早期按键处理器要接住它',
    );
    expect(find.byType(RailNavigator), findsOneWidget);
  });

  testWidgets('切走画布页会自动退出全屏', (tester) async {
    final container = await _openCanvas(tester);
    await _enterFullscreen(tester);
    expect(container.read(immersiveFullscreenProvider), ImmersiveSurface.canvas);

    // 沉浸模式里左栏是藏起来的，走状态层模拟"中栏被切到别的页"的另一条路径。
    container.read(shellTargetProvider.notifier).clear();
    await _pumpCanvas(tester);

    expect(
      container.read(immersiveFullscreenProvider),
      isNull,
      reason: '画布已经不在了，留下一个满屏标记会得到一间没有出口的房间',
    );
    expect(find.byType(RailNavigator), findsOneWidget);
  });
}
