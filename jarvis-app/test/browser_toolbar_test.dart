import 'package:jarvis_app/src/core/browser/browser_models.dart';
import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/features/browser/browser_toolbar.dart';
import 'package:jarvis_app/src/features/browser/browser_zoom_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({
  required BrowserSessionState state,
  ValueChanged<String>? onSubmit,
  ValueChanged<String>? onReload,
  ValueChanged<BrowserSource>? onSource,
  VoidCallback? onOpenExternal,
  VoidCallback? onZoomIn,
  VoidCallback? onZoomOut,
  VoidCallback? onZoomReset,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 200,
          child: Column(
            children: <Widget>[
              BrowserToolbar(
                state: state,
                onSubmit: onSubmit ?? (_) {},
                onBack: () {},
                onForward: () {},
                onReload: onReload ?? (_) {},
                onStop: () {},
                onOpenExternal: onOpenExternal ?? () {},
                onSelectSource: onSource ?? (_) {},
                onZoomIn: onZoomIn ?? () {},
                onZoomOut: onZoomOut ?? () {},
                onZoomReset: onZoomReset ?? () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('空态：地址提示可见，导航按钮全部禁用', (tester) async {
    await tester.pumpWidget(_harness(state: const BrowserSessionState()));

    expect(find.text('输入 HTTP(S) 地址'), findsOneWidget);

    IconButton buttonWith(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

    expect(buttonWith(Icons.arrow_back_rounded).onPressed, isNull);
    expect(buttonWith(Icons.arrow_forward_rounded).onPressed, isNull);
    expect(buttonWith(Icons.refresh_rounded).onPressed, isNull);
    expect(buttonWith(Icons.open_in_new_rounded).onPressed, isNull);
    expect(
      find.byKey(kBrowserZoomButtonKey),
      findsNothing,
      reason: '没有页面、比例也是 100%，缩放入口不该出现',
    );
  });

  testWidgets('有页面时显示逻辑地址，加载中把刷新换成停止', (tester) async {
    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          target: const ServerPortTarget(host: '127.0.0.1', port: 3000),
          internalUri: Uri.parse('http://127.0.0.1:5555/'),
          address: 'localhost:3000',
          loading: true,
          progress: 0.4,
          canGoBack: true,
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'localhost:3000');
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);

    IconButton buttonWith(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));
    expect(buttonWith(Icons.arrow_back_rounded).onPressed, isNotNull);
    expect(buttonWith(Icons.arrow_forward_rounded).onPressed, isNull);
  });

  testWidgets('回车提交地址', (tester) async {
    String? submitted;
    await tester.pumpWidget(
      _harness(
        state: const BrowserSessionState(),
        onSubmit: (value) => submitted = value,
      ),
    );

    await tester.enterText(find.byType(TextField), '3000');
    await tester.testTextInput.receiveAction(TextInputAction.done);

    expect(submitted, '3000');
  });

  testWidgets('刷新交出地址栏此刻的文本，而不是上一次提交的地址', (tester) async {
    String? reloaded;
    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          target: InternetTarget(Uri.parse('https://www.deepseek.com/')),
          internalUri: Uri.parse('https://www.deepseek.com/'),
          pageUri: Uri.parse('https://www.deepseek.com/harness/'),
          address: 'https://www.deepseek.com/harness/',
        ),
        onReload: (value) => reloaded = value,
      ),
    );

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    expect(reloaded, 'https://www.deepseek.com/harness/');

    await tester.enterText(find.byType(TextField), 'https://example.com/x');
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    expect(reloaded, 'https://example.com/x', reason: '用户改了地址但没回车，刷新不能丢掉它');
  });

  testWidgets('地址栏文字与标签页同字号，来源徽标走中性灰', (tester) async {
    await tester.pumpWidget(_harness(state: const BrowserSessionState()));

    final field = tester.widget<TextField>(find.byType(TextField));
    // 右栏标签页（_PanelTab）用 sm，地址栏跟它一致，同一栏里不再一大一小。
    expect(field.style?.fontSize, AppFontSize.sm, reason: '与标签页同字号');
    expect(field.style?.height, AppLineHeight.tight, reason: '单行控件用 tight 行高');
    expect(field.decoration?.hintStyle?.fontSize, AppFontSize.sm);

    // 行盒钉死在 sm × tight + 1dp，并垂直居中在 28dp 的地址框里。若让 28dp
    // 直接约束输入框，多出来的空间一旦被算到文字上方，字就贴底
    // （截图实测偏下 4.5dp）。
    expect(
      tester.getSize(find.byType(TextField)).height,
      closeTo(kBrowserAddressLineBox, 0.5),
      reason: '行盒只比文字高 1dp',
    );
    expect(
      tester.getCenter(find.byType(TextField)).dy,
      closeTo(tester.getCenter(find.byType(BrowserToolbar)).dy, 0.5),
      reason: '地址文字要和整条栏同轴',
    );

    // 徽标：文字是 badge 字阶，图标不再用主色（主色只留给真正的强调件）。
    final label = tester.widget<Text>(find.text('服务器'));
    expect(label.style?.fontSize, AppFontSize.xs);
    final context = tester.element(find.byType(BrowserToolbar));
    final palette = AppPalette.of(context);
    final icon = tester.widget<Icon>(find.byIcon(Icons.dns_rounded));
    expect(icon.color, palette.text.tertiary);
    expect(icon.color, isNot(Theme.of(context).colorScheme.primary));
  });

  testWidgets('来源徽标可切换，选项覆盖三个来源', (tester) async {
    BrowserSource? selected;
    await tester.pumpWidget(
      _harness(
        state: const BrowserSessionState(),
        onSource: (value) => selected = value,
      ),
    );

    expect(find.text('服务器'), findsOneWidget);
    await tester.tap(find.text('服务器'));
    await tester.pumpAndSettle();

    expect(find.text('本机'), findsOneWidget);
    expect(find.text('互联网'), findsOneWidget);

    await tester.tap(find.text('本机'));
    await tester.pumpAndSettle();

    expect(selected, BrowserSource.client);
  });

  testWidgets('100% 时工具条不显示缩放入口', (tester) async {
    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          internalUri: Uri.parse('https://example.com/'),
          address: 'https://example.com/',
        ),
      ),
    );

    expect(
      find.byKey(kBrowserZoomButtonKey),
      findsNothing,
      reason: '默认比例下不该有一枚用不上的放大镜',
    );
    // 外部打开仍在原位，工具条其余按钮不受影响。
    expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget);
  });

  testWidgets('比例离开 100% 后入口出现，位置在外部打开左侧', (tester) async {
    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          internalUri: Uri.parse('https://example.com/'),
          address: 'https://example.com/',
          zoom: 1.10,
        ),
      ),
    );

    expect(find.byKey(kBrowserZoomButtonKey), findsOneWidget);

    final zoomX = tester.getCenter(find.byKey(kBrowserZoomButtonKey)).dx;
    final externalX = tester
        .getCenter(find.byIcon(Icons.open_in_new_rounded))
        .dx;
    expect(zoomX, lessThan(externalX), reason: '缩放要排在外部打开左边');
  });

  testWidgets('缩放浮层显示比例，三个动作各自回调且不收起浮层', (tester) async {
    var zoomIn = 0;
    var zoomOut = 0;
    var reset = 0;

    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          internalUri: Uri.parse('https://example.com/'),
          address: 'https://example.com/',
          zoom: 1.10,
        ),
        onZoomIn: () => zoomIn++,
        onZoomOut: () => zoomOut++,
        onZoomReset: () => reset++,
      ),
    );

    await tester.tap(find.byKey(kBrowserZoomButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('110%'), findsOneWidget);
    expect(find.text('重置'), findsOneWidget);
    // 与右栏顶部标签页同字号：浮层文字不再比标签大一号。
    expect(
      tester.widget<Text>(find.byKey(kBrowserZoomPercentKey)).style?.fontSize,
      AppFontSize.sm,
    );
    expect(
      tester.widget<Text>(find.text('重置')).style?.fontSize,
      AppFontSize.sm,
    );

    await tester.tap(find.byKey(kBrowserZoomOutKey));
    await tester.pump();
    await tester.tap(find.byKey(kBrowserZoomInKey));
    await tester.pump();
    await tester.tap(find.byKey(kBrowserZoomResetKey));
    await tester.pumpAndSettle();

    expect(zoomOut, 1);
    expect(zoomIn, 1);
    expect(reset, 1);
    expect(
      find.byKey(kBrowserZoomPercentKey),
      findsOneWidget,
      reason: '调档时浮层要保持打开，连点几档不用每次重新点开',
    );
  });

  testWidgets('浮层里的三个按钮成组，不摊成一条散线', (tester) async {
    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          internalUri: Uri.parse('https://example.com/'),
          address: 'https://example.com/',
          zoom: 1.10,
        ),
      ),
    );

    await tester.tap(find.byKey(kBrowserZoomButtonKey));
    await tester.pumpAndSettle();

    double centerX(Key key) => tester.getCenter(find.byKey(key)).dx;
    final outX = centerX(kBrowserZoomOutKey);
    final inX = centerX(kBrowserZoomInKey);
    final resetX = centerX(kBrowserZoomResetKey);

    // 三枚控件紧邻：−/+ 各占 24 的命中区，间距只来自命中区本身；
    // 重置前面只留 6dp 的视觉缝。
    expect(inX - outX, lessThanOrEqualTo(30));
    expect(resetX - inX, lessThanOrEqualTo(45));
    expect(
      inX,
      greaterThan(centerX(kBrowserZoomPercentKey)),
      reason: '按钮组整体贴在比例右侧',
    );
  });

  testWidgets('25% 时缩小禁用，500% 时放大禁用', (tester) async {
    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          internalUri: Uri.parse('https://example.com/'),
          address: 'https://example.com/',
          zoom: 0.25,
        ),
      ),
    );
    await tester.tap(find.byKey(kBrowserZoomButtonKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(kBrowserZoomOutKey)).onPressed,
      isNull,
    );

    // 关掉浮层，换到上限再开一次。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _harness(
        state: BrowserSessionState(
          internalUri: Uri.parse('https://example.com/'),
          address: 'https://example.com/',
          zoom: 5,
        ),
      ),
    );
    await tester.tap(find.byKey(kBrowserZoomButtonKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(kBrowserZoomInKey)).onPressed,
      isNull,
    );
  });
}
