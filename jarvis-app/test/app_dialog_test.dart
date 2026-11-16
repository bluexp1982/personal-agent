import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/core/ui/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const Key _dialogKey = Key('test-dialog');
const Key _panelKey = Key('test-panel');
const Key _closeKey = Key('test-close');
const Key _leadingKey = Key('test-leading');

/// 弹窗要挂在一个真路由上：`Esc`、`maybePop` 与遮罩都依赖 `DialogRoute`。
///
/// 主题走真实的 [buildAppTheme]：弹窗底色按亮度分档，用默认 `ThemeData` 测不出
/// 「深色下弹窗比页面亮一档」这条口径。
Future<void> _open(
  WidgetTester tester,
  Widget dialog, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  showAppDialog<void>(context, builder: (_) => dialog),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

AppDialog _dialog({
  String? title = '标题',
  Widget? child,
  bool scrollable = true,
  Widget? leading,
  Widget? titleTrailing,
  bool withClose = true,
  VoidCallback? onClose,
}) {
  return AppDialog(
    dialogKey: _dialogKey,
    panelKey: _panelKey,
    closeKey: withClose ? _closeKey : null,
    title: title,
    titleTrailing: titleTrailing,
    leading: leading,
    scrollable: scrollable,
    onClose: onClose,
    child: child ?? const SizedBox(height: 120, child: Text('内容')),
  );
}

void main() {
  testWidgets('标题行 48、关闭钮 32，上边距 = 下边距 = 右边距 = 8', (tester) async {
    await _open(tester, _dialog());

    final panel = tester.getRect(find.byKey(_panelKey));
    final close = tester.getRect(find.byKey(_closeKey));
    expect(panel.height, lessThan(200), reason: '内容自适应高度，不铺满整屏');
    expect(close.size, const Size(32, 32));
    expect(close.top - panel.top, 8, reason: '上边距');
    expect(close.top - panel.top, panel.right - close.right, reason: '上 = 右');
    expect(
      close.top - panel.top,
      kAppDialogTitleBarHeight - close.height - (close.top - panel.top),
      reason: '上 = 下',
    );
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('浅色：底色取 surface、遮罩固定 scrim@45%，外部改不了', (tester) async {
    await _open(tester, _dialog());

    final scheme = Theme.of(tester.element(find.byKey(_panelKey))).colorScheme;
    expect(
      tester.widget<Dialog>(find.byKey(_dialogKey)).backgroundColor,
      scheme.surface,
      reason: '浅色下与页面同色，层级交给遮罩与圆角',
    );

    final barrier = tester
        .widgetList<ModalBarrier>(find.byType(ModalBarrier))
        .last;
    expect(
      barrier.color,
      scheme.scrim.withValues(alpha: kAppDialogBarrierAlpha),
      reason: '遮罩深浅由组件决定，调用方没有覆盖入口',
    );
  });

  testWidgets('深色：底色抬到 surfaceContainerHigh，与页面底拉得开', (tester) async {
    await _open(tester, _dialog(), brightness: Brightness.dark);

    final scheme = Theme.of(tester.element(find.byKey(_panelKey))).colorScheme;
    expect(
      tester.widget<Dialog>(find.byKey(_dialogKey)).backgroundColor,
      scheme.surfaceContainerHigh,
      reason: '深色页面底接近纯黑，弹窗必须比它亮一档才看得出浮层',
    );
    expect(
      scheme.surfaceContainerHigh,
      isNot(scheme.surface),
      reason: '两者一旦相等，深色下弹窗就又和页面糊在一起了',
    );

    // 相对亮度守卫：深色下这一档至少要拉到 1.2:1，否则等于没改。
    final dialogL = scheme.surfaceContainerHigh.computeLuminance();
    final pageL = scheme.surface.computeLuminance();
    final ratio = (dialogL + 0.05) / (pageL + 0.05);
    expect(ratio, greaterThan(1.2), reason: '深色弹窗与页面底的对比约 $ratio');

    final barrier = tester
        .widgetList<ModalBarrier>(find.byType(ModalBarrier))
        .last;
    expect(
      barrier.color,
      scheme.scrim.withValues(alpha: kAppDialogBarrierAlpha),
      reason: '遮罩两个主题同一档，不按亮度分叉',
    );
  });

  testWidgets('标题统一 22 / w700', (tester) async {
    await _open(tester, _dialog());

    final title = tester.widget<Text>(find.text('标题'));
    expect(title.style?.fontSize, AppFontSize.display);
    expect(title.style?.fontWeight, AppWeight.bold);
  });

  testWidgets('前置动作贴左沿 8，标题可居中', (tester) async {
    await _open(
      tester,
      _dialog(
        title: '选择目录',
        leading: IconButton(
          key: _leadingKey,
          tooltip: '上一级',
          onPressed: () {},
          style: kAppDialogIconButtonStyle,
          icon: const Icon(Icons.chevron_left, size: 20),
        ),
      ),
    );

    final panel = tester.getRect(find.byKey(_panelKey));
    final leading = tester.getRect(find.byKey(_leadingKey));
    expect(leading.left - panel.left, 8);
    expect(leading.size, const Size(32, 32));
    expect(find.byTooltip('上一级'), findsOneWidget);
  });

  testWidgets('自定义右侧动作时不再画默认关闭钮', (tester) async {
    await _open(
      tester,
      _dialog(
        titleTrailing: TextButton(onPressed: () {}, child: const Text('完成')),
        withClose: false,
      ),
    );

    expect(find.text('完成'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
  });

  testWidgets('scrollable：内容自带滚动；关闭滚动时交回调用方', (tester) async {
    await _open(tester, _dialog());
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.getSize(find.byType(SingleChildScrollView)).width, 520);

    await tester.pumpWidget(const SizedBox());
    await _open(tester, _dialog(scrollable: false));
    expect(find.byType(SingleChildScrollView), findsNothing);
  });

  testWidgets('Esc 关闭弹窗', (tester) async {
    await _open(tester, _dialog());
    expect(find.byKey(_dialogKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(_dialogKey), findsNothing);
  });

  testWidgets('关闭回调可带返回值：由调用方接管', (tester) async {
    Object? popped;
    await _open(
      tester,
      Builder(
        builder: (context) => _dialog(
          onClose: () {
            popped = false;
            Navigator.of(context).pop(false);
          },
        ),
      ),
    );

    await tester.tap(find.byKey(_closeKey));
    await tester.pumpAndSettle();
    expect(popped, false);
    expect(find.byKey(_dialogKey), findsNothing);
  });
}
