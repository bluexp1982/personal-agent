import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/features/call/call_page.dart';

/// 「实时通话」占位页的守护测试。
///
/// 这一页目前没有行为，价值全在"原型该有的东西都在、且矮屏不炸"：
/// 页头三段、头像环下的身份与计时、打断提示、四枚控制键、AI 生成声明。
/// 接入真实通话后，断言里的 `03:12` 会变成运行时计时，那时只该改这一处。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.seed,
            brightness: brightness,
          ),
          useMaterial3: true,
        ),
        home: const CallPage(bottomInset: 96),
      ),
    );
    await tester.pump();
  }

  testWidgets('页头三段齐全：标题、选择情景、字幕', (tester) async {
    await pump(tester);

    expect(find.text('实时通话'), findsOneWidget);
    expect(find.text('选择情景'), findsOneWidget);
    expect(find.byTooltip('字幕'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「选择情景」胶囊落在页头中线上', (tester) async {
    const width = 390.0;
    await pump(tester, size: const Size(width, 844));

    final pill = tester.getRect(find.byKey(kCallScenarioPillKey));
    expect(
      (pill.center.dx - width / 2).abs(),
      lessThan(1),
      reason: '标题在左、字幕在右，胶囊要独立居中',
    );
    // 标题与字幕仍在两端。
    final title = tester.getRect(find.text('实时通话'));
    expect(title.left, lessThan(pill.left));
    final caption = tester.getRect(find.byTooltip('字幕'));
    expect(caption.right, greaterThan(pill.right));
  });

  testWidgets('主体是身份与计时，脚下是打断提示', (tester) async {
    await pump(tester);

    expect(find.text('Jarvis'), findsOneWidget);
    expect(find.text('03:12'), findsOneWidget);
    expect(find.text('说话或点击打断'), findsOneWidget);
    expect(find.text('内容由 AI 生成'), findsOneWidget);
    // 环心是原型里那张对话头像，不是图标占位。
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('四枚控制键都在，且是占位（点了不崩）', (tester) async {
    await pump(tester);

    for (final label in <String>['麦克风', '关闭麦克风', '关闭摄像头', '挂断']) {
      final finder = find.byTooltip(label);
      expect(finder, findsOneWidget, reason: '缺了「$label」控制键');
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('矮屏 320×568 不溢出，内容不压到底部导航的留白里', (tester) async {
    await pump(tester, size: const Size(320, 568));

    expect(tester.takeException(), isNull);
    expect(find.text('Jarvis'), findsOneWidget);
    expect(find.text('内容由 AI 生成'), findsOneWidget);
  });

  testWidgets('深色主题同样可用', (tester) async {
    await pump(tester, brightness: Brightness.dark);

    expect(find.text('实时通话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
