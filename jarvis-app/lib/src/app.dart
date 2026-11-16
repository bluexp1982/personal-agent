import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/design/app_theme.dart';
import 'core/theme_mode.dart';
import 'core/ui/liquid_glass_nav.dart';
import 'core/theme_packs.dart';
import 'core/window_chrome.dart';
import 'router.dart';

/// 应用外壳。M0 只有主题与路由，业务页在 M5 逐步填入。
///
/// 主题由 `themeSelectionProvider` 决定（跟随系统 / 浅色 / 深色 / 个性主题）：
/// 前三档交给 `MaterialApp.themeMode`，个性主题则把主题包那一套同时塞进
/// `theme` 与 `darkTheme`，让包的明暗基线说了算。换肤不会重建路由，
/// 当前页面栈、SSH 终端会话与滚动位置都保留。
class JarvisApp extends ConsumerWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(themeSelectionProvider);
    // 主题包可能还没拉到、也可能已被删除：此时 [activeThemeSpec] 为 null，
    // 整个应用平滑回落到内置主题，不弹错框、不白屏。
    final spec = ref.watch(activeThemeSpecProvider);
    final custom = spec == null
        ? null
        : buildAppTheme(spec.brightness, colors: spec.colors);

    return MaterialApp.router(
      title: 'Jarvis',
      debugShowCheckedModeBanner: false,
      // 主题装配在 `core/design/app_theme.dart`：色阶、字阶、调色板都在那里，
      // 这里只声明"浅色一份、深色一份"，个性主题再覆盖成包里的那一套。
      theme: custom ?? buildAppTheme(Brightness.light),
      darkTheme: custom ?? buildAppTheme(Brightness.dark),
      // 个性主题选了但包不可用时按"跟随系统"渲染：留着 ThemeMode.custom
      // 却没有可用的颜色，只会让用户看到一个说不清状态的界面。
      themeMode: custom == null && selection.isCustom
          ? ThemeMode.system
          : selection.materialMode,
      routerConfig: appRouter,
      // macOS 隐藏了系统标题栏：内容铺到窗口顶端，但这 28dp 要留给红绿灯。
      // 补在 `MediaQuery.padding` 上，`SafeArea` 与各页面的 `AppBar` 都会自动让开。
      //
      // 外面再包一层 [TitleBarClickReporter]：逐次告诉原生"这次点击是不是
      // 落在标题栏空白区"，栏头按钮上的连点（例如连按两次后退）才不会被
      // 当成"双击标题栏"把窗口缩放掉。
      builder: (context, child) => TitleBarClickReporter(
        child: HiddenWindowTitleBarInset(
          // 液态玻璃包刻意不依赖 Material：缺祖先时它内部的 Text 会画出黄色
          // 双下划线。开关关时原样返回，不往树上多加一层。
          child: maybeGlassMaterialAncestor(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
