import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_surface.dart';
import 'package:jarvis_app/src/core/design/app_theme_spec.dart';
import 'package:jarvis_app/src/core/ui/app_page_scaffold.dart';

/// 整窗底色的守护测试。
///
/// 底色只有一个出处（[appSurfaceGradient]）与一个容器（[AppPageScaffold]）：
/// 色调来自 `palette.surface.topTint`，**透明 = 纯色底（内置两套都是）**，
/// 主题包显式给色才有顶部渐变。四条约束一旦被绕过，界面上就会重新出现
/// "别的页面比 Agent 页冷一点"、"详情页转场时透出下层列表"、
/// "壳内标签页重复铺底多出一条横向色带"：
/// 1. 首段必须是不透明色（预乘过），否则整页路由垫底时会透；
/// 2. 没有显式底色的整页要自己铺底，Scaffold 必须透明；
/// 3. 祖先已经铺过（骨架里的标签页）时不能再铺第二层；
/// 4. 色调透明时不能把"透明"当成"16% 的黑"叠上去。
///
/// 显式底色（宽屏内嵌的 `paneSurfaceColor`、全屏黑底）走原样返回，
/// 这里一并守住——它是宽屏三栏像素不变的依据。
void main() {
  group('appSurfaceGradient', () {
    test('内置浅色：不铺渐变，三段同色且等于页面底色', () {
      final scheme = ColorScheme.fromSeed(seedColor: AppColors.seed);
      final palette = AppPalette.forBrightness(Brightness.light);
      final gradient = appSurfaceGradient(palette, scheme);

      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      expect(gradient.stops, <double>[0, kSurfaceTopTintStop, 1]);
      expect(gradient.colors.length, 3);

      // 内置两套的色调是透明的：整窗就是一块纯色底。
      expect(palette.surface.topTint.a, 0);
      expect(gradient.colors.first, scheme.surface);
      expect(gradient.colors[1], scheme.surface);
      expect(gradient.colors[2], scheme.surface);
      // 纯色也要不透明：整页路由垫底时不能透出下层列表。
      expect(gradient.colors.first.a, 1.0);
    });

    test('内置深色：同样不铺渐变，末段跟着深色 surface 走', () {
      final scheme = ColorScheme.fromSeed(
        seedColor: AppColors.seed,
        brightness: Brightness.dark,
      );
      final palette = AppPalette.forBrightness(Brightness.dark);
      final gradient = appSurfaceGradient(palette, scheme);

      expect(palette.surface.topTint.a, 0);
      expect(gradient.colors.first, scheme.surface);
      expect(gradient.colors[2], scheme.surface);
      expect(scheme.brightness, Brightness.dark);
    });

    test('主题包给了 surface.top_tint：首段是色调与底色的叠加，不是裸色调', () {
      final scheme = ColorScheme.fromSeed(seedColor: AppColors.seed);
      final tint = const Color(0xFF00A6B2);
      final palette = AppPalette.forBrightness(Brightness.light).overrideWith(
        AppThemeColors(<String, Color>{'surface.top_tint': tint}),
      );

      expect(palette.surface.topTint, tint);
      final first = appSurfaceGradient(palette, scheme).colors.first;
      expect(
        first,
        Color.alphaBlend(
          tint.withValues(alpha: kSurfaceTopTintAlpha),
          scheme.surface,
        ),
      );
      expect(first, isNot(scheme.surface), reason: '给了色调就该看得出渐变');
      expect(first.a, 1.0);
    });

    test('包没写 surface.top_tint 时沿用内置（不铺）', () {
      final scheme = ColorScheme.fromSeed(seedColor: AppColors.seed);
      final palette = AppPalette.forBrightness(Brightness.light).overrideWith(
        AppThemeColors(<String, Color>{'text.tertiary': const Color(0xFF9A9AA6)}),
      );

      expect(palette.surface.topTint.a, 0);
      expect(appSurfaceGradient(palette, scheme).colors.first, scheme.surface);
    });
  });

  group('AppPageScaffold', () {
    testWidgets('无显式底色：自铺整窗渐变，Scaffold 透明', (tester) async {
      await tester.pumpWidget(
        _host(const AppPageScaffold(body: SizedBox.expand())),
      );

      final gradient = _gradientOf(tester);
      expect(gradient, isNotNull, reason: '整页路由必须自己垫一层渐变');
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.transparent,
        reason: 'Scaffold 有不透明底色就会把渐变整块盖住',
      );
    });

    testWidgets('显式底色：原样返回，不铺渐变（宽屏内嵌 / 全屏黑底）', (tester) async {
      const color = Color(0xFF123456);
      await tester.pumpWidget(
        _host(
          const AppPageScaffold(backgroundColor: color, body: SizedBox.expand()),
        ),
      );

      expect(_gradientOf(tester), isNull);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        color,
      );
    });

    testWidgets('祖先已铺过（PageBackdropScope）：不再重复铺底', (tester) async {
      await tester.pumpWidget(
        _host(
          const PageBackdropScope(
            child: AppPageScaffold(body: SizedBox.expand()),
          ),
        ),
      );

      expect(
        _gradientOf(tester),
        isNull,
        reason: '骨架里已经有一层渐变，标签页再铺一次会在顶部拉出色带',
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        Colors.transparent,
      );
    });
  });
}

Widget _host(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: AppColors.seed),
      useMaterial3: true,
    ),
    home: child,
  );
}

/// 测试树里由本组件铺的那层渐变（忽略 Material 内部的其它装饰）。
LinearGradient? _gradientOf(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).gradient is LinearGradient,
  );
  if (finder.evaluate().isEmpty) {
    return null;
  }
  return (tester.widget<DecoratedBox>(finder.first).decoration as BoxDecoration)
      .gradient
      as LinearGradient;
}
