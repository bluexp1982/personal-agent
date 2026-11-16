import 'dart:math' as math;

import 'package:jarvis_app/src/core/design/app_flow_border.dart';
import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/at_skill_provider.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/composer_flow_border.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 流光层的边界测试。
///
/// 只用固定 `pump`，不碰 `pumpAndSettle`：激活后是无限循环动画，前者会挂死。
/// 面板内容给一个带 key 的定高方块，用来确认"挂不挂流光都不改几何"。

const Key _panelKey = Key('flow-panel');

Widget _harness({required bool active, double width = 420}) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.dark),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: ComposerFlowBorder(
            active: active,
            radius: 20,
            child: Container(
              key: _panelKey,
              height: 120,
              decoration: const BoxDecoration(color: Color(0xFF1B1F27)),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _flowPaint() {
  return find.descendant(
    of: find.byType(ComposerFlowBorder),
    matching: find.byType(CustomPaint),
  );
}

void main() {
  testWidgets('未激活时不挂绘图层', (tester) async {
    await tester.pumpWidget(_harness(active: false));

    expect(_flowPaint(), findsNothing);
  });

  testWidgets('激活后有绘图层且面板矩形不变', (tester) async {
    await tester.pumpWidget(_harness(active: false));
    final idle = tester.getRect(find.byKey(_panelKey));

    await tester.pumpWidget(_harness(active: true));
    // 淡入 280ms：推进到完成后才一定在画。
    await tester.pump(AppFlowBorder.fadeDuration);

    expect(_flowPaint(), findsOneWidget);
    expect(tester.getRect(find.byKey(_panelKey)), idle);

    // 转两帧：动画自驱重绘，不该牵动布局。
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getRect(find.byKey(_panelKey)), idle);

    // 摘掉树，别把无限动画留给下一个用例。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('淡出结束后撤掉绘图层', (tester) async {
    await tester.pumpWidget(_harness(active: true));
    await tester.pump(AppFlowBorder.fadeDuration);
    expect(_flowPaint(), findsOneWidget);

    await tester.pumpWidget(_harness(active: false));
    // 过了半程仍在画。
    await tester.pump(
      Duration(
        milliseconds: AppFlowBorder.fadeDuration.inMilliseconds ~/ 2,
      ),
    );
    expect(_flowPaint(), findsOneWidget);

    await tester.pump(AppFlowBorder.fadeDuration);
    await tester.pump();
    expect(_flowPaint(), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('渐变随圈数正向旋转：Canvas y 轴向下，正角度即视觉顺时针', () {
    final gradient = AppFlowBorder.gradient(turns: 0.25);

    expect(gradient.transform, isA<GradientRotation>());
    expect(
      (gradient.transform! as GradientRotation).radians,
      closeTo(math.pi / 2, 1e-9),
    );
    // 色板首尾同色：转满一圈回到起点时没有跳变。
    expect(gradient.colors.first, gradient.colors.last);
  });

  test('透明度乘进色板而不是靠 Paint 颜色', () {
    final gradient = AppFlowBorder.gradient(turns: 0, opacity: 0.5);

    expect(gradient.colors.every((color) => color.a == 0.5), isTrue);
  });

  testWidgets('ChatComposer 把 flowing 原样接到流光层', (tester) async {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    Widget harness({required bool flowing}) {
      return ProviderScope(
        overrides: [
          atSkillsProvider.overrideWith((ref) async => const <SkillInfo>[]),
        ],
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: ChatComposer(
              controller: controller,
              sending: flowing,
              flowing: flowing,
              onSend: () {},
              onStop: () {},
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(harness(flowing: false));
    expect(
      tester.widget<ComposerFlowBorder>(find.byType(ComposerFlowBorder)).active,
      isFalse,
    );

    await tester.pumpWidget(harness(flowing: true));
    await tester.pump(AppFlowBorder.fadeDuration);
    expect(
      tester.widget<ComposerFlowBorder>(find.byType(ComposerFlowBorder)).active,
      isTrue,
    );

    // 拆树，别把无限动画留给下一个用例。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
