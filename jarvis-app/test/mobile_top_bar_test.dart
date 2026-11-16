import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/core/ui/agent_menu.dart';
import 'package:jarvis_app/src/core/ui/liquid_glass_nav.dart';
import 'package:jarvis_app/src/core/ui/mobile_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 把被测量的小部件摆在 400 宽的页头里，避免 `AppBar` 的默认留白影响判断。
///
/// 玻璃相关用例把 [showBack] 关掉：返回钮本身也是一枚 `MobileTopBarButton`，
/// 留着它会让 `GlassContainer`/`BackdropFilter` 的计数多出一层。
Widget _host(
  Widget child, {
  Brightness brightness = Brightness.light,
  bool showBack = true,
  bool dark = false,
}) {
  return MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.seed,
        brightness: brightness,
      ),
      useMaterial3: true,
    ),
    home: Scaffold(
      appBar: MobileAppBar(
        title: '页面标题',
        showBack: showBack,
        dark: dark,
      ),
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  );
}

/// 页头声明给系统的那份状态栏样式（`AppBar` 自己会把它挂到
/// `AnnotatedRegion<SystemUiOverlayStyle>` 上，状态栏那一行就按它画）。
SystemUiOverlayStyle _overlayOf(WidgetTester tester) {
  final style = tester
      .widget<AppBar>(find.byType(AppBar))
      .systemOverlayStyle;
  expect(style, isNotNull, reason: '不给的话 AppBar 会按透明底色推成白图标');
  return style!;
}

void main() {
  // 既有几何用例测的是回退路径的确定性；玻璃路径由下面单独一组覆盖。
  setUp(() => liquidGlassNavEnabled = false);
  tearDown(() => liquidGlassNavEnabled = kLiquidGlassNavDefault);

  testWidgets('圆钮是 38dp 正圆，图标 18；紧凑版 30 / 16', (tester) async {
    await tester.pumpWidget(
      _host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MobileTopBarButton(
              glyph: MobileTopBarGlyph.search,
              tooltip: '搜索',
              onPressed: () {},
            ),
            MobileTopBarButton(
              icon: Icons.refresh,
              tooltip: '紧凑刷新',
              compact: true,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    expect(tester.getSize(find.byTooltip('搜索')), const Size.square(38));
    expect(
      tester.getSize(find.byTooltip('紧凑刷新')),
      const Size.square(30),
    );
    // 自绘图标收到 18（紧凑版 16）。页头的返回钮也是一枚自绘图标，按 tooltip 收窄。
    final glyph = tester.widget<MobileTopBarIcon>(
      find.descendant(
        of: find.byTooltip('搜索'),
        matching: find.byType(MobileTopBarIcon),
      ),
    );
    expect(glyph.size, kMobileTopBarIconSize);
  });

  testWidgets('组合胶囊：两枚各 38、中间 1px 分隔，整组一枚胶囊', (tester) async {
    await tester.pumpWidget(
      _host(
        MobileTopBarButtonGroup(
          children: <Widget>[
            MobileTopBarButton(
              bare: true,
              icon: Icons.tune,
              tooltip: '设置',
              onPressed: () {},
            ),
            MobileTopBarButton(
              bare: true,
              glyph: MobileTopBarGlyph.more,
              tooltip: '更多',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    final group = tester.getSize(find.byType(MobileTopBarButtonGroup));
    expect(group.height, 38);
    expect(group.width, 77, reason: '38 + 1（分隔线）+ 38');

    final left = tester.getRect(find.byTooltip('设置'));
    final right = tester.getRect(find.byTooltip('更多'));
    expect(left.width, 38);
    expect(right.left - left.right, 1, reason: '两格之间只有 1dp 分隔线');
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色变体：图标走白色系，不铺暖白玻璃', (tester) async {
    await tester.pumpWidget(
      _host(
        ColoredBox(
          color: Colors.black,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: MobileTopBarButton(
              dark: true,
              icon: Icons.save_alt,
              tooltip: '另存为',
              onPressed: () {},
            ),
          ),
        ),
        brightness: Brightness.light,
      ),
    );

    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byTooltip('另存为'),
        matching: find.byType(Icon),
      ),
    );
    expect(
      icon.color?.r,
      closeTo(1, 0.01),
      reason: '黑底上不能用正文灰（浅色主题下是深灰）',
    );
    expect(icon.color?.g, closeTo(1, 0.01));
  });

  testWidgets('页头几何：54 高、返回钮 38、标题 16/w700', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(appBar: MobileAppBar(title: '页面标题'), body: SizedBox()),
      ),
    );

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.toolbarHeight, kMobileTopBarMinHeight);
    expect(
      tester.getSize(find.byType(AppBar)).height,
      kMobileTopBarMinHeight,
      reason: '没有 bottom 时页头就是 54',
    );
    expect(tester.getSize(find.byTooltip('返回')), const Size.square(38));

    final title = tester.widget<Text>(find.text('页面标题'));
    expect(title.style?.fontSize, AppFontSize.lg);
    expect(title.style?.fontWeight, AppWeight.bold);

    // 返回钮离左边缘 12：leadingWidth 54 = 12 + 38 + 4。
    expect(tester.getTopLeft(find.byTooltip('返回')).dx, kMobileTopBarSideInset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回钮走 maybePop：能退回上一页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(
                      appBar: MobileAppBar(title: '子页'),
                      body: SizedBox(),
                    ),
                  ),
                ),
                child: const Text('进入子页'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('进入子页'));
    await tester.pumpAndSettle();
    expect(find.text('子页'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.text('子页'), findsNothing);
    expect(find.text('进入子页'), findsOneWidget);
  });

  testWidgets('菜单触发器换成圆钮后仍能开合（triggerHandlesTap: false）', (tester) async {
    await tester.pumpWidget(
      _host(
        AgentMenu<String>(
          width: 180,
          triggerHandlesTap: false,
          groups: const <AgentMenuGroup<String>>[
            AgentMenuGroup<String>(
              items: <AgentMenuItem<String>>[
                AgentMenuItem<String>(value: 'rename', label: '重命名'),
              ],
            ),
          ],
          onSelected: (_) {},
          builder: (context, controller, open, hovering) => MobileTopBarButton(
            glyph: MobileTopBarGlyph.more,
            tooltip: '更多操作',
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsNothing);
  });

  testWidgets('页头里的文字动作被压到 38 高，与圆钮同高', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: MobileAppBar(
            title: '对话',
            actions: <Widget>[
              TextButton(onPressed: () {}, child: const Text('管理')),
              MobileTopBarButton(
                icon: Icons.refresh,
                tooltip: '刷新',
                onPressed: () {},
              ),
            ],
          ),
          body: const SizedBox(),
        ),
      ),
    );

    expect(
      tester.getSize(find.widgetWithText(TextButton, '管理')).height,
      kMobileTopBarButtonSize,
    );
    expect(tester.getSize(find.byTooltip('刷新')), const Size.square(38));
    expect(tester.takeException(), isNull);
  });

  group('液态玻璃背板', () {
    setUp(() => liquidGlassNavEnabled = true);

    testWidgets('单枚圆钮：背板交给 GlassContainer，几何仍 38', (tester) async {
      await tester.pumpWidget(
        _host(
          MobileTopBarButton(
            icon: Icons.add,
            tooltip: '新建',
            onPressed: () {},
          ),
          showBack: false,
        ),
      );

      expect(find.byType(GlassContainer), findsOneWidget);
      expect(
        find.byType(BackdropFilter),
        findsNothing,
        reason: '玻璃路径不该再叠一层旧的背景模糊',
      );
      expect(tester.getSize(find.byTooltip('新建')), const Size.square(38));
      expect(
        tester.getSize(find.byType(GlassContainer)),
        const Size.square(38),
        reason: '只换材质，不动按钮几何',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('整组只建一层玻璃：两格 38、中间 1dp、组宽 77', (tester) async {
      await tester.pumpWidget(
        _host(
          MobileTopBarButtonGroup(
            children: <Widget>[
              MobileTopBarButton(
                bare: true,
                icon: Icons.add,
                tooltip: '新建',
                onPressed: () {},
              ),
              MobileTopBarButton(
                bare: true,
                glyph: MobileTopBarGlyph.more,
                tooltip: '更多',
                onPressed: () {},
              ),
            ],
          ),
          showBack: false,
        ),
      );

      // 整组只有一层玻璃：格子里若再各建一层，胶囊中间会叠出两条折射边缘。
      expect(find.byType(GlassContainer), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MobileTopBarButtonGroup),
          matching: find.byType(GlassContainer),
        ),
        findsOneWidget,
      );

      final group = tester.getSize(find.byType(MobileTopBarButtonGroup));
      expect(group, const Size(77, 38));
      expect(
        tester.getSize(find.byType(GlassContainer)),
        const Size(77, 38),
        reason: '玻璃背板与整组同宽同高，不能比胶囊小一圈',
      );

      final left = tester.getRect(find.byTooltip('新建'));
      final right = tester.getRect(find.byTooltip('更多'));
      expect(left.width, 38);
      expect(right.left - left.right, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('开关关闭：没有 GlassContainer，回退旧 BackdropFilter', (tester) async {
      liquidGlassNavEnabled = false;
      await tester.pumpWidget(
        _host(
          MobileTopBarButton(
            icon: Icons.add,
            tooltip: '新建',
            onPressed: () {},
          ),
          showBack: false,
        ),
      );

      expect(find.byType(GlassContainer), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tester.getSize(find.byTooltip('新建')), const Size.square(38));
      expect(tester.takeException(), isNull);
    });
  });

  // 状态栏那行时间 / 信号由系统画，深浅完全取决于页头声明的这份样式：
  // iOS 认 `statusBarBrightness`（背景明暗），Android 认 `statusBarIconBrightness`。
  group('状态栏明暗跟随主题', () {
    testWidgets('浅色主题：深色时间与图标', (tester) async {
      await tester.pumpWidget(
        _host(const SizedBox.shrink(), brightness: Brightness.light),
      );

      final style = _overlayOf(tester);
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.statusBarBrightness, Brightness.light);
      expect(
        style.statusBarColor,
        Colors.transparent,
        reason: '状态栏底色仍由页面渐变透上来',
      );
      expect(
        style.systemNavigationBarColor,
        isNull,
        reason: '不能带预设里的黑导航栏',
      );
    });

    testWidgets('深色主题：浅色时间与图标', (tester) async {
      await tester.pumpWidget(
        _host(const SizedBox.shrink(), brightness: Brightness.dark),
      );

      final style = _overlayOf(tester);
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.statusBarBrightness, Brightness.dark);
    });

    testWidgets('黑底查看器（dark: true）在浅色主题下仍是浅色', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox.shrink(),
          brightness: Brightness.light,
          dark: true,
        ),
      );

      final style = _overlayOf(tester);
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.statusBarBrightness, Brightness.dark);
    });
  });
}
