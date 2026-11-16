import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/core/ui/adaptive_card_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每张卡片自带 Key 与固定高度，方便断言宽度和行内位置。
Widget _harness({required double width, int count = 4}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: AdaptiveCardList(
            padding: const EdgeInsets.all(16),
            itemCount: count,
            spacing: 12,
            itemBuilder: (_, index) =>
                SizedBox(key: ValueKey<int>(index), height: 60),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('宽屏按最小宽度拆成多列，不再每项平铺整行', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(width: 900));

    final first = tester.getSize(find.byKey(const ValueKey<int>(0)));
    final second = tester.getSize(find.byKey(const ValueKey<int>(1)));

    // 可用宽度 900 - 32 = 868，每列不小于 320 → 两列。
    expect(first.width, greaterThanOrEqualTo(kAdaptiveCardMinWidth));
    expect(first.width, lessThan(450));
    expect(second.width, first.width);
    // 同一行的两项顶部对齐。
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<int>(0))).dy,
      tester.getTopLeft(find.byKey(const ValueKey<int>(1))).dy,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<int>(0))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey<int>(2))).dy),
    );
  });

  testWidgets('窄屏仍是一列铺满整行', (tester) async {
    tester.view.physicalSize = const Size(360, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(width: 360, count: 2));

    // 可用宽度 360 - 32 = 328 < 320 + 12，放不下两列。
    expect(tester.getSize(find.byKey(const ValueKey<int>(0))).width, 328);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<int>(1))).dy,
      greaterThan(tester.getTopLeft(find.byKey(const ValueKey<int>(0))).dy),
    );
  });

  testWidgets('scrollable: false 时不带内层滚动，可直接嵌进列表', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              AdaptiveCardList(
                scrollable: false,
                padding: const EdgeInsets.all(16),
                itemCount: 3,
                spacing: 12,
                itemBuilder: (_, index) =>
                    SizedBox(key: ValueKey<int>(index), height: 60),
              ),
            ],
          ),
        ),
      ),
    );

    // 内层不再有自己的滚动视图；列宽公式仍按 320 生效。
    expect(find.byType(SingleChildScrollView), findsNothing);
    final first = tester.getSize(find.byKey(const ValueKey<int>(0)));
    expect(first.width, greaterThanOrEqualTo(kAdaptiveCardMinWidth));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<int>(1))).dy,
      tester.getTopLeft(find.byKey(const ValueKey<int>(0))).dy,
    );
  });

  testWidgets('统一卡片壳：浅底、圆角 md、无描边，选中换成主色混合底', (tester) async {
    tester.view.physicalSize = const Size(700, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveCardList(
            itemCount: 2,
            isSelected: (index) => index == 1,
            itemBuilder: (_, index) =>
                SizedBox(key: ValueKey<int>(index), height: 60),
          ),
        ),
      ),
    );

    final scheme = Theme.of(
      tester.element(find.byKey(const ValueKey<int>(0))),
    ).colorScheme;

    // 常驻底：surfaceContainerLow，圆角 md，不带描边（旧 Card 的 border 已去掉）。
    final base = find.byWidgetPredicate(
      (widget) =>
          widget is Material && widget.color == scheme.surfaceContainerLow,
    );
    expect(base, findsOneWidget);
    final shell = tester.widget<Material>(base);
    expect(shell.borderRadius, BorderRadius.circular(AppRadius.md));
    expect(shell.shape, isNull, reason: '统一卡片不再有描边');
    expect(find.byType(Card), findsNothing);

    // 选中底：主色 8% 与卡底的混合，等价于原来的 Card 底 + selectedTileColor。
    final selectedColor = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.08),
      scheme.surfaceContainerLow,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Material && widget.color == selectedColor,
      ),
      findsOneWidget,
    );
  });

  testWidgets('卡片内文统一几何：34 图标块、14/w500 标题、无右箭头', (tester) async {
    tester.view.physicalSize = const Size(700, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveCardList(
            padding: const EdgeInsets.all(16),
            itemCount: 1,
            itemBuilder: (context, _) => AdaptiveCardRow(
              icon: Icons.graphic_eq,
              iconColor: Theme.of(context).colorScheme.primary,
              title: '卡片标题',
              meta: '元信息',
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(AdaptiveCardIconTile)),
      const Size(34, 34),
    );

    final title = tester.widget<Text>(find.text('卡片标题'));
    expect(title.style?.fontSize, AppFontSize.base);
    expect(title.style?.fontWeight, AppWeight.medium);

    final meta = tester.widget<Text>(find.text('元信息'));
    expect(meta.style?.fontSize, AppFontSize.sm);

    // 三处统一后不再有 Material 默认行与右箭头。
    expect(find.byType(ListTile), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });
}
