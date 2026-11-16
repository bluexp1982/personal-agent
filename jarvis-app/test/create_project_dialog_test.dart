import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/projects/create_project_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打开弹窗的入口按钮；测试用它触发一次 `showCreateProjectDialog`。
Widget _harness({ValueChanged<bool>? onResult}) {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(null)],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final created = await showCreateProjectDialog(context);
                onResult?.call(created);
              },
              child: const Text('新建项目'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, '新建项目'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('新建项目是垂直居中的对话框，右上角有关闭按钮', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await _open(tester);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing, reason: '不再是底部抽屉');
    expect(find.text('新建项目'), findsWidgets);

    // 垂直居中：对话框中心与窗口中心（400）几乎重合。
    final rect = tester.getRect(find.byType(Dialog));
    expect(rect.center.dy, closeTo(400, 2));

    // 关闭按钮在对话框右上角。
    final close = find.byTooltip('关闭');
    expect(close, findsOneWidget);
    expect(
      tester.getCenter(close).dx,
      greaterThan(rect.center.dx),
      reason: '关闭按钮在标题行右端',
    );

    // 左右内边距对称：输入框到两边的距离相等。
    final surface = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    final field = tester.getRect(find.byType(TextField));
    expect(
      field.left - surface.left,
      closeTo(surface.right - field.right, 0.5),
      reason: '左右边距不同会让内容看起来歪向一边',
    );

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('Git 仓库是一个开关选项：勾上才出现仓库校验说明', (tester) async {
    await tester.pumpWidget(_harness());
    await _open(tester);

    // 默认不勾：提示里明确说明没有 Git 操作。
    expect(find.textContaining('不勾选 Git 时只要求目录存在'), findsOneWidget);
    expect(find.text('必须是 Git 仓库根目录'), findsNothing);

    // 与「编辑配置」的「支持读图」同款列表行，不再用描边卡片。
    expect(
      find.widgetWithText(SwitchListTile, 'Git 仓库'),
      findsOneWidget,
      reason: '开关样式要与编辑配置一致',
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('code.allow_roots'), findsOneWidget);
    expect(find.text('必须是 Git 仓库根目录'), findsOneWidget);
    expect(find.textContaining('不勾选 Git 时只要求目录存在'), findsNothing);

    // 没有界面文案还在区分 CODE / WORK。
    expect(find.text('CODE'), findsNothing);
    expect(find.text('WORK'), findsNothing);
  });

  testWidgets('目录选择是叠在新建项目上面的弹窗，关掉后表单还在', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await _open(tester);

    await tester.tap(find.text('选择服务端目录'));
    await tester.pumpAndSettle();

    // 两层弹窗同时在树上：新建项目没有被替换掉。
    expect(find.byType(Dialog), findsNWidgets(2));
    expect(find.text('选择目录'), findsOneWidget);
    expect(find.textContaining('使用此目录'), findsOneWidget);
    // 列表里不再单独放「上一级」，翻上一级交给标题栏的返回箭头。
    expect(find.text('上一级'), findsNothing);
    expect(find.byTooltip('上一级'), findsOneWidget);

    final picker = find.byType(Dialog).last;
    await tester.tap(
      find.descendant(of: picker, matching: find.byTooltip('关闭')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('选择服务端目录'), findsOneWidget);
  });

  testWidgets('关闭弹窗返回 false，不创建项目', (tester) async {
    bool? result;
    await tester.pumpWidget(_harness(onResult: (value) => result = value));
    await _open(tester);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });
}
