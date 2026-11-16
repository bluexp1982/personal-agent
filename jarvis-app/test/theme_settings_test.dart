import 'dart:io';

import 'package:jarvis_app/src/app.dart';
import 'package:jarvis_app/src/core/design/app_builtin_themes.dart';
import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/design/app_theme_spec.dart';
import 'package:jarvis_app/src/core/secret_store.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/theme_mode.dart';
import 'package:jarvis_app/src/features/settings/settings_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

/// 每个用例一个临时目录当 `SecretStore` 的回退目录：测试环境没有钥匙串，
/// `SecretStore` 会自己退到文件，于是"落盘 → 重开 → 恢复"能真跑一遍 IO。
Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('agent-theme-');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

SecretStore _store(Directory dir) => SecretStore(fallbackDirectory: dir);

ProviderContainer _container(SecretStore store) {
  final container = ProviderContainer(
    overrides: [
      secretStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// 一个最小主题包：深色 + 只改了两格。
AppThemeSpec _spec({
  String id = 'nightfall',
  Color? success,
  Color? seed,
}) {
  return AppThemeSpec(
    id: id,
    name: '夜幕',
    version: '1.0.0',
    brightness: Brightness.dark,
    author: '阿吉',
    colors: AppThemeColors(<String, Color>{
      'seed': ?seed,
      'status.success': ?success,
      'text.tertiary': const Color(0xFF9A9AA6),
    }),
  );
}

void main() {
  test('主题名的解析与落盘字符串一一对应，脏值一律失败', () {
    for (final mode in ThemeMode.values) {
      expect(themeModeFromName(themeModeName(mode)), mode);
    }
    expect(themeModeFromName(null), isNull);
    expect(themeModeFromName(''), isNull);
    expect(themeModeFromName('Dark'), isNull);
    expect(themeModeFromName('dark '), isNull);
    expect(themeModeFromName('auto'), isNull);

    for (final choice in ThemeChoice.values) {
      expect(themeChoiceFromName(themeChoiceName(choice)), choice);
    }
    // 旧版本写的 `light|dark|system` 原样可用，不需要迁移。
    expect(themeChoiceFromName('light'), ThemeChoice.light);
    expect(themeChoiceFromName('neon'), isNull);
  });

  test('选择会落盘，重启后能恢复', () async {
    final dir = _tempDir();
    final store = _store(dir);
    final first = _container(store);

    expect(first.read(themeSelectionProvider).choice, ThemeChoice.system);
    await first
        .read(themeSelectionProvider.notifier)
        .selectMode(ThemeChoice.dark);
    expect(first.read(themeSelectionProvider).choice, ThemeChoice.dark);
    expect(first.read(themeSelectionProvider).materialMode, ThemeMode.dark);
    expect(await store.read(kThemeModeKey), 'dark');

    // 换容器 + 新的 SecretStore 实例，模拟"重启后从盘上读回来"。
    final reopened = _container(_store(dir));
    await reopened.read(themeSelectionProvider.notifier).restore();
    expect(reopened.read(themeSelectionProvider).choice, ThemeChoice.dark);
  });

  test('存储里的脏值回落跟随系统', () async {
    final dir = _tempDir();
    await _store(dir).write(kThemeModeKey, 'neon');

    final container = _container(_store(dir));
    await container.read(themeSelectionProvider.notifier).restore();
    expect(container.read(themeSelectionProvider).choice, ThemeChoice.system);
  });

  test('选个性主题：缓存 spec，重启后连颜色一起恢复', () async {
    final dir = _tempDir();
    final store = _store(dir);
    final first = _container(store);

    final spec = _spec(success: const Color(0xFF4ADE80));
    await first.read(themeSelectionProvider.notifier).selectTheme(spec);

    final selection = first.read(themeSelectionProvider);
    expect(selection.choice, ThemeChoice.custom);
    expect(selection.themeId, 'nightfall');
    expect(selection.materialMode, ThemeMode.light, reason: '个性主题自己决定明暗');
    expect(await store.read(kThemeModeKey), 'custom');
    expect(await store.read(kThemeIdKey), 'nightfall');
    expect(await store.read(kThemeSpecKey), isNotNull);

    final reopened = _container(_store(dir));
    await reopened.read(themeSelectionProvider.notifier).restore();
    final restored = reopened.read(themeSelectionProvider);
    expect(restored.choice, ThemeChoice.custom);
    expect(restored.themeId, 'nightfall');
    expect(
      restored.spec?.colors['status.success'],
      const Color(0xFF4ADE80),
      reason: '缓存要带着颜色回来，首帧才不会闪',
    );
  });

  test('缓存丢了就回落跟随系统，不留一个空壳选择', () async {
    final dir = _tempDir();
    final store = _store(dir);
    await store.write(kThemeModeKey, 'custom');
    await store.write(kThemeIdKey, 'nightfall');

    final container = _container(_store(dir));
    await container.read(themeSelectionProvider.notifier).restore();
    expect(container.read(themeSelectionProvider).choice, ThemeChoice.system);
  });

  test('删除当前主题包后平滑回落跟随系统，并清掉缓存', () async {
    final dir = _tempDir();
    final store = _store(dir);
    final container = _container(store);

    await container
        .read(themeSelectionProvider.notifier)
        .selectTheme(_spec());
    await container.read(themeSelectionProvider.notifier).clearCustom();

    expect(container.read(themeSelectionProvider).choice, ThemeChoice.system);
    expect(await store.read(kThemeModeKey), 'system');
    expect(await store.read(kThemeIdKey), isNull);
    expect(await store.read(kThemeSpecKey), isNull);
  });

  test('颜色覆盖只改声明的格子，其余仍取自内置派生值', () {
    final base = AppPalette.forBrightness(Brightness.dark);
    final spec = _spec(success: const Color(0xFF4ADE80));

    final overridden = base.overrideWith(spec.colors);
    expect(overridden.status.success, const Color(0xFF4ADE80));
    expect(
      overridden.status.danger,
      base.status.danger,
      reason: '没覆盖的状态色必须原样保留',
    );
    expect(overridden.text.tertiary, const Color(0xFF9A9AA6));
    expect(overridden.message.userBubble, base.message.userBubble);
    expect(overridden.terminal.background, base.terminal.background);

    // 空覆盖是恒等变换：内置两套主题的行为不能被这次改造改掉。
    expect(identical(base.overrideWith(AppThemeColors.empty), base), isTrue);
  });

  test('种子色进入 ColorScheme，语义色进入 AppPalette', () {
    final plain = buildAppTheme(Brightness.dark);
    final themed = buildAppTheme(
      Brightness.dark,
      colors: _spec(seed: const Color(0xFF635BFF)).colors,
    );

    expect(
      themed.colorScheme.primary,
      isNot(plain.colorScheme.primary),
      reason: '换种子色就该换整套色阶',
    );
    final plainPalette = plain.extension<AppPalette>()!;
    expect(
      themed.extension<AppPalette>()?.status.success,
      plainPalette.status.success,
      reason: '没覆盖 success 时保持内置值',
    );
    expect(
      themed.extension<AppPalette>()?.text.tertiary,
      const Color(0xFF9A9AA6),
    );
  });

  test('accent / surface 两组覆盖落到 AppPalette', () {
    final theme = buildAppTheme(
      Brightness.dark,
      colors: AppThemeColors(<String, Color>{
        'accent.project_start': const Color(0xFF6EEC47),
        'accent.ssh_start': const Color(0xFF00A6B2),
        'surface.top_tint': const Color(0xFF123456),
      }),
    );

    final palette = theme.extension<AppPalette>()!;
    expect(palette.accent.projectStart, const Color(0xFF6EEC47));
    expect(
      palette.accent.projectEnd,
      builtinThemeColors(Brightness.dark)['accent.project_end'],
      reason: '没覆盖的端点保持内置 spec 的值',
    );
    expect(palette.accent.sshStart, const Color(0xFF00A6B2));
    expect(
      palette.surface.topTint,
      const Color(0xFF123456),
      reason: '页面顶部渐变色调要跟着包走',
    );
  });

  test('旧包残留的 icon 段被忽略，不影响解析', () {
    // `icon.folder_selected` 已移除；用户装过的旧包还带着这一段，
    // 解析必须宽松，否则升级后主题会整包不可用。
    final colors = AppThemeColors.fromJson(<String, dynamic>{
      'accent': <String, dynamic>{'project_start': '#6EEC47'},
      'icon': <String, dynamic>{'folder_selected': '#8B84FF'},
    });

    expect(colors['accent.project_start'], const Color(0xFF6EEC47));
    expect(colors['icon.folder_selected'], isNull);
    expect(colors.groups.contains('icon'), isFalse, reason: 'icon 组已退出包格式');
  });

  test('内置主题不铺顶部渐变；包只在显式给 surface.top_tint 时才铺', () {
    for (final brightness in Brightness.values) {
      final builtin = buildAppTheme(brightness).extension<AppPalette>()!;
      expect(
        builtin.surface.topTint.a,
        0,
        reason: '$brightness 内置主题应是纯色底',
      );
    }

    // 只改 accent（不写 surface.top_tint）不会顺带长出渐变。
    final accentOnly = buildAppTheme(
      Brightness.dark,
      colors: AppThemeColors(<String, Color>{
        'accent.project_start': const Color(0xFF6EEC47),
      }),
    ).extension<AppPalette>()!;
    expect(accentOnly.accent.projectStart, const Color(0xFF6EEC47));
    expect(accentOnly.surface.topTint.a, 0);
  });

  test('内置浅 / 深各有一组强调色（来自内置 spec）', () {
    final light = buildAppTheme(Brightness.light)
        .extension<AppPalette>()!
        .accent;
    final dark = buildAppTheme(Brightness.dark)
        .extension<AppPalette>()!
        .accent;

    expect(
      light.projectStart,
      builtinThemeColors(Brightness.light)['accent.project_start'],
    );
    expect(
      dark.projectStart,
      builtinThemeColors(Brightness.dark)['accent.project_start'],
    );
    expect(light.projectStart, isNot(dark.projectStart));
  });

  test('scheme 组覆盖整站骨架：页面底、前景与主色一起变', () {
    final theme = buildAppTheme(
      Brightness.dark,
      colors: AppThemeColors(<String, Color>{
        'scheme.surface': const Color(0xFF000000),
        'scheme.on_surface': const Color(0xFFE5E5E5),
        'scheme.primary': const Color(0xFF00A600),
        'scheme.on_primary': const Color(0xFF000000),
        'scheme.outline_variant': const Color(0xFF2B2B2B),
      }),
    );

    expect(theme.colorScheme.surface, const Color(0xFF000000));
    expect(
      theme.scaffoldBackgroundColor,
      const Color(0xFF000000),
      reason: '页面底必须跟着 scheme.surface 走，否则会出现"卡片黑了、页面还是灰的"',
    );
    expect(theme.colorScheme.onSurface, const Color(0xFFE5E5E5));
    expect(theme.colorScheme.primary, const Color(0xFF00A600));
    expect(theme.colorScheme.onPrimary, const Color(0xFF000000));
    expect(
      theme.extension<AppPalette>()?.text.primary,
      const Color(0xFFE5E5E5),
      reason: 'AppPalette 必须在 copyWith 之后派生，正文才不会留在旧灰阶',
    );
  });

  test('不写 scheme 时与内置主题逐字段一致', () {
    final plain = buildAppTheme(Brightness.dark);
    final onlyText = buildAppTheme(
      Brightness.dark,
      colors: AppThemeColors(<String, Color>{
        'text.tertiary': const Color(0xFF9A9AA6),
      }),
    );

    expect(onlyText.colorScheme.surface, plain.colorScheme.surface);
    expect(onlyText.colorScheme.primary, plain.colorScheme.primary);
    expect(onlyText.scaffoldBackgroundColor, plain.scaffoldBackgroundColor);
  });

  test('AppThemeColors 解析容错：脏色值跳过，不认识的键忽略', () {
    final colors = AppThemeColors.fromJson(<String, dynamic>{
      'seed': '#635BFF',
      'scheme': <String, dynamic>{
        'surface': '#000000',
        'on_surface': '#E5E5E5',
        'surface_container_highest': 'oops',
      },
      'text': <String, dynamic>{'tertiary': 'nope', 'control': '#A8AEB6'},
      'terminal': <String, dynamic>{'bright_green': 'not-a-color'},
      // `surface` 是合法分组名，但值必须是对象：这里给字符串，整组被跳过。
      'surface': '#FFFFFF',
    });

    expect(colors['seed'], const Color(0xFF635BFF));
    expect(colors['scheme.surface'], const Color(0xFF000000));
    expect(colors['scheme.on_surface'], const Color(0xFFE5E5E5));
    expect(colors['scheme.surface_container_highest'], isNull);
    expect(colors['text.control'], const Color(0xFFA8AEB6));
    expect(colors['text.tertiary'], isNull);
    expect(colors['terminal.bright_green'], isNull);
    // 分组值不是对象时整组忽略，不能被当成 `scheme.surface`。
    expect(colors['surface'], isNull);
    expect(colors['scheme.surface'], const Color(0xFF000000));

    // 写回去还能再读出来（缓存走的是这条路径）。
    final round = AppThemeColors.fromJson(colors.toJson());
    expect(round, colors);
  });

  testWidgets('设置页选深色：立即生效并落盘', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = _tempDir();
    final store = _store(dir);
    final container = _container(store);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SettingsSectionView(
              session: _session,
              section: SettingsSection.appearance,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('主题'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('个性主题'), findsOneWidget);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(container.read(themeSelectionProvider).choice, ThemeChoice.dark);
    expect(await store.read(kThemeModeKey), 'dark');
    expect(tester.takeException(), isNull, reason: '360~420dp 下分段控件不应溢出');
  });

  testWidgets('选个性主题会展开主题包面板（空态给安装入口）', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = _container(_store(_tempDir()));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SettingsSectionView(
              session: _session,
              section: SettingsSection.appearance,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('个性主题'));
    await tester.pumpAndSettle();

    expect(container.read(themeSelectionProvider).choice, ThemeChoice.custom);
    expect(find.text('还没有安装主题包'), findsOneWidget);
    expect(find.text('安装主题包（.zip）'), findsOneWidget);
  });

  testWidgets('JarvisApp 的 themeMode 跟着 provider 变，个性主题用包里的配色', (
    tester,
  ) async {
    final container = _container(_store(_tempDir()));

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JarvisApp()),
    );
    // 只关心 MaterialApp 的装配；未配对时外壳会自己落到配对页，这里不等它稳定。
    await tester.pump();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );

    await container
        .read(themeSelectionProvider.notifier)
        .selectMode(ThemeChoice.dark);
    await tester.pump();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    await container
        .read(themeSelectionProvider.notifier)
        .selectTheme(_spec(success: const Color(0xFF4ADE80)));
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light, reason: '个性主题固定按包里的明暗渲染');
    expect(app.theme?.brightness, Brightness.dark);
    expect(
      app.theme?.extension<AppPalette>()?.status.success,
      const Color(0xFF4ADE80),
    );
  });
}
