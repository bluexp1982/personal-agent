import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/features/conversations/composer_context_ring.dart';

/// 只装一枚环：它不吃 provider，也不需要整块输入栏。
Widget _host({
  int tokens = 0,
  int window = 0,
  bool compacting = false,
  VoidCallback? onOpen,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: ContextUsageRing(
          contextTokens: tokens,
          contextWindow: window,
          compacting: compacting,
          onOpenCompaction: onOpen,
        ),
      ),
    ),
  );
}

void main() {
  group('tooltip 文案', () {
    test('有数据时按参考口径：百分比一位小数 + 大写 K', () {
      expect(
        formatContextTooltip(contextTokens: 168000, contextWindow: 1000000),
        '16.8% · 168.0K / 1000.0K 上下文已使用',
      );
    });

    test('不足 1000 的 token 原样显示', () {
      expect(
        formatContextTooltip(contextTokens: 640, contextWindow: 128000),
        '0.5% · 640 / 128.0K 上下文已使用',
      );
    });

    test('超出窗口时百分比夹在 100%', () {
      expect(
        formatContextTooltip(contextTokens: 2000000, contextWindow: 1000000),
        '100.0% · 2000.0K / 1000.0K 上下文已使用',
      );
    });

    test('没有用量与窗口未知各有自己的提示', () {
      expect(
        formatContextTooltip(contextTokens: 0, contextWindow: 1000000),
        '暂无上下文数据',
      );
      expect(
        formatContextTooltip(contextTokens: 168000, contextWindow: 0),
        '模型上下文窗口未配置',
      );
    });
  });

  testWidgets('没有用量时整枚环零尺寸、不占位也不弹提示', (tester) async {
    await tester.pumpWidget(_host(window: 1000000));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(ContextUsageRing)), Size.zero);
    expect(
      find.descendant(
        of: find.byType(ContextUsageRing),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
      reason: '空态不该挂一个"暂无数据"的悬停气泡',
    );
  });

  testWidgets('有用量时环按比例画弧，提示带具体数值', (tester) async {
    await tester.pumpWidget(_host(tokens: 168000, window: 1000000));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(ContextUsageRing)),
      const Size(26, 26),
      reason: '命中盒 26，环本身 20',
    );

    final tooltip = tester.widget<Tooltip>(
      find.descendant(
        of: find.byType(ContextUsageRing),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, '16.8% · 168.0K / 1000.0K 上下文已使用');

    // 环本体是 20×20 的 CustomPaint，进度画在它上面。
    final paint = find.descendant(
      of: find.byType(ContextUsageRing),
      matching: find.byType(CustomPaint),
    );
    expect(paint, findsWidgets);
    expect(tester.getSize(paint.first), const Size.square(20));
  });

  testWidgets('窗口未配置时提示窗口缺失，不显示假百分比', (tester) async {
    await tester.pumpWidget(_host(tokens: 168000));
    await tester.pumpAndSettle();

    final tooltip = tester.widget<Tooltip>(
      find.descendant(
        of: find.byType(ContextUsageRing),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, '模型上下文窗口未配置');
  });

  group('点击查看摘要', () {
    testWidgets('可点时提示补一句，并暴露按钮语义', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(tokens: 168000, window: 1000000, onOpen: () {}),
      );
      await tester.pumpAndSettle();

      final tooltip = tester.widget<Tooltip>(
        find.descendant(
          of: find.byType(ContextUsageRing),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, '16.8% · 168.0K / 1000.0K 上下文已使用；点击查看摘要');
      expect(find.bySemanticsLabel(RegExp('点击查看摘要')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('点环触发一次回调', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(tokens: 168000, window: 1000000, onOpen: () => opened++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('没有回调时既不多提一句、也没有按钮语义', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(tokens: 168000, window: 1000000));
      await tester.pumpAndSettle();

      final tooltip = tester.widget<Tooltip>(
        find.descendant(
          of: find.byType(ContextUsageRing),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, '16.8% · 168.0K / 1000.0K 上下文已使用');
      expect(find.bySemanticsLabel(RegExp('点击查看摘要')), findsNothing);

      // 点一下也不该有副作用：没有回调，也没有按钮语义。
      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();
      handle.dispose();
    });
  });

  testWidgets('整理中环改成转圈，停下后回到占比', (tester) async {
    await tester.pumpWidget(
      _host(tokens: 168000, window: 1000000, compacting: true),
    );
    await tester.pump();

    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '转圈靠重复动画驱动，应当持续排帧',
    );
    // 尺寸、命中盒都不变：转圈只是换了一种画法。
    expect(tester.getSize(find.byType(ContextUsageRing)), const Size(26, 26));

    // 换回非整理态：控制器停下，占比过渡（200ms）结束后不再排帧。
    await tester.pumpWidget(_host(tokens: 168000, window: 1000000));
    await tester.pumpAndSettle();
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '整理结束后不该再有帧',
    );
  });
}
