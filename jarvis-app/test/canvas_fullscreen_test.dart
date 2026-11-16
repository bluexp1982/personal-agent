import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/features/canvas/canvas_control_bar.dart';
import 'package:jarvis_app/src/features/canvas/canvas_demo_page.dart';
import 'package:jarvis_app/src/features/shell/embedded_toolbar.dart';
import 'package:jarvis_app/src/features/shell/immersive_fullscreen.dart';

/// 画布页带着常驻的连线动效（无限循环的 Ticker），`pumpAndSettle` 等不到静止，
/// 与 `canvas_demo_test.dart` 同口径：一律用固定 pump。
Widget _harness({bool embedded = false, bool immersive = false}) {
  return ProviderScope(
    child: MaterialApp(
      home: CanvasDemoPage(embedded: embedded, immersive: immersive),
    ),
  );
}

Future<void> _pumpCanvas(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

void main() {
  testWidgets('点栏头全屏进的是沉浸模式，不另开页面', (tester) async {
    await tester.pumpWidget(_harness(embedded: true));
    await _pumpCanvas(tester);

    expect(_container(tester).read(immersiveFullscreenProvider), isNull);
    expect(find.byKey(kCanvasFullscreenKey), findsOneWidget);

    await tester.tap(find.byKey(kCanvasFullscreenKey));
    await _pumpCanvas(tester);

    expect(
      _container(tester).read(immersiveFullscreenProvider),
      ImmersiveSurface.canvas,
      reason: '与终端、图片预览同一个状态，只是宿主换成中栏画布',
    );
    // 没有 push 新路由：画布页本身仍在树里，控制器与整张图都没被丢掉。
    expect(find.byType(CanvasDemoPage), findsOneWidget);
  });

  testWidgets('沉浸模式下栏头、控制条、提示条全部让位，画布还在', (tester) async {
    await tester.pumpWidget(_harness(embedded: true));
    await _pumpCanvas(tester);

    final editor = tester.element(find.byKey(kCanvasEditorKey));
    final page = tester.state(find.byType(CanvasDemoPage));
    expect(find.byType(EmbeddedToolbar), findsOneWidget);
    expect(find.byType(CanvasControlBar), findsOneWidget);
    expect(find.textContaining('滚轮缩放'), findsOneWidget);

    await tester.pumpWidget(_harness(embedded: true, immersive: true));
    await _pumpCanvas(tester);

    expect(
      tester.state(find.byType(CanvasDemoPage)),
      same(page),
      reason: '页面 State（MobX 控制器）不能重建',
    );
    expect(find.byType(EmbeddedToolbar), findsNothing, reason: '栏头整条收起');
    expect(find.byType(CanvasControlBar), findsNothing, reason: '控制条收起');
    expect(find.textContaining('滚轮缩放'), findsNothing, reason: '提示条收起');
    expect(find.byKey(kCanvasFullscreenKey), findsNothing, reason: '全屏按钮也随之消失');
    // 画布不能被重挂：`Column` 的槽位恒定，`Expanded` 里仍是同一个 Element。
    expect(find.byKey(kCanvasEditorKey), findsOneWidget);
    expect(
      tester.element(find.byKey(kCanvasEditorKey)),
      same(editor),
      reason: '进出全屏只换占位，编辑器（视口 / 选中 / 拖拽）必须原样留着',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('整页形态（窄屏）不提供全屏按钮：本身已经铺满', (tester) async {
    await tester.pumpWidget(_harness());
    await _pumpCanvas(tester);

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byKey(kCanvasFullscreenKey), findsNothing);
    expect(find.byType(CanvasControlBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
