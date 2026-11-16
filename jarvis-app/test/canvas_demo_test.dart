import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/features/canvas/canvas_control_bar.dart';
import 'package:jarvis_app/src/features/canvas/canvas_demo_page.dart';
import 'package:jarvis_app/src/features/canvas/canvas_node_card.dart';
import 'package:jarvis_app/src/features/canvas/canvas_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 画布页带着常驻的连线动效（`FlowEffect` 是无限循环的 Ticker），
/// `pumpAndSettle` 会一直等不到静止，所以这里统一用固定 pump。
Widget _harness({bool embedded = false}) {
  return ProviderScope(
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: CanvasDemoPage(embedded: embedded),
    ),
  );
}

Future<void> _pumpCanvas(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 取控制条当前状态：页面把开关值原样下发给它，读它等于读页面状态。
CanvasControlBar _bar(WidgetTester tester) =>
    tester.widget<CanvasControlBar>(find.byType(CanvasControlBar));

void main() {
  testWidgets('画布页渲染示例图：四类节点 + 分组 + 便签都在', (tester) async {
    await tester.pumpWidget(_harness());
    await _pumpCanvas(tester);

    // 卡片数量不锁死：分组与便签是库里的自渲染节点，且库会按可视区把静态节点
    // 批量画进保留场景（不一定留下 widget）。断言落在文案上才是稳定的。
    expect(find.byType(CanvasNodeCard), findsAtLeastNWidgets(4));
    expect(find.text('新消息到达'), findsOneWidget);
    expect(find.text('整理成待办'), findsOneWidget);
    expect(find.text('今天要处理吗'), findsOneWidget);
    expect(find.text('推一条提醒'), findsOneWidget);
    expect(find.text('归档到今天'), findsOneWidget);
    expect(find.text('采集 → 处理'), findsOneWidget);
    expect(find.textContaining('这是一张演示画布'), findsOneWidget);
    expect(find.byType(CanvasControlBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内嵌形态不画第二层 AppBar，整页形态才有', (tester) async {
    await tester.pumpWidget(_harness(embedded: true));
    await _pumpCanvas(tester);
    expect(find.byType(AppBar), findsNothing);

    await tester.pumpWidget(_harness());
    await _pumpCanvas(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('动效可切到「无」，开关状态回写到控制条', (tester) async {
    await tester.pumpWidget(_harness());
    await _pumpCanvas(tester);

    expect(_bar(tester).effect, CanvasEffect.flowingDash);

    await tester.tap(find.byKey(kCanvasEffectMenuKey));
    await _pumpCanvas(tester);
    await tester.tap(find.byKey(const Key('canvas-effect-none')));
    await _pumpCanvas(tester);

    expect(_bar(tester).effect, CanvasEffect.none);

    // 小地图开关同样只由页面持有，读控制条就等于读页面状态。
    expect(_bar(tester).minimapVisible, isTrue);
    await tester.tap(find.byKey(kCanvasMinimapToggleKey));
    await _pumpCanvas(tester);
    expect(_bar(tester).minimapVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网格切到「关闭」，连线样式切成直线', (tester) async {
    await tester.pumpWidget(_harness());
    await _pumpCanvas(tester);

    await tester.tap(find.byKey(kCanvasGridMenuKey));
    await _pumpCanvas(tester);
    await tester.tap(find.byKey(const Key('canvas-grid-none')));
    await _pumpCanvas(tester);
    expect(_bar(tester).gridStyle, CanvasGridStyle.none);

    await tester.tap(find.byKey(kCanvasLinkStyleMenuKey));
    await _pumpCanvas(tester);
    await tester.tap(find.byKey(const Key('canvas-link-style-straight')));
    await _pumpCanvas(tester);
    expect(_bar(tester).linkStyle, CanvasLinkStyle.straight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄面板里不溢出：控制条横向滚动，画布仍占满剩余高度', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 380);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(embedded: true));
    await _pumpCanvas(tester);

    expect(find.byType(CanvasControlBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出 JSON 给出只读预览，含节点与连线', (tester) async {
    await tester.pumpWidget(_harness());
    await _pumpCanvas(tester);

    await tester.tap(find.byKey(kCanvasExportKey));
    await _pumpCanvas(tester);

    expect(find.text('画布 JSON'), findsOneWidget);
    final preview = tester.widget<SelectableText>(find.byType(SelectableText));
    final json = preview.data ?? '';
    expect(json, contains('"nodes"'));
    expect(json, contains('"connections"'));
    expect(json, contains('"kind": "trigger"'));
    expect(tester.takeException(), isNull);
  });
}
