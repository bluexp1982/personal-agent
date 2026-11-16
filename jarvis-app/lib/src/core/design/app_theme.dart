import 'package:flutter/material.dart';

import 'app_builtin_themes.dart';
import 'app_palette.dart';
import 'app_theme_spec.dart';
import 'app_tokens.dart';

/// 主题装配：全站只在这里创建 `ThemeData`。
///
/// 改造前这段写在 `app.dart` 的私有方法里，只设了种子色与圆角；
/// 字号、文字灰阶、状态色全靠各处 `copyWith` 自己拼。抽出来之后，
/// "主题"这件事有了唯一入口：加一档 token、换一次种子色、调一次字阶，
/// 都只改这里与 `app_tokens.dart`。
///
/// 明暗两套共用同一段逻辑：`ColorScheme.fromSeed` 负责色阶，
/// [AppPalette] 负责语义，[AppFontSize] 负责字阶。
///
/// 装配顺序固定为三层：**派生 → 内置 spec（`app_builtin_themes.dart`）→ 用户主题包**。
/// 前两层就是内置浅色 / 深色，第三层为空时行为等于"只用内置"。
///
/// [colors] 是主题包的稀疏覆盖：种子色参与 `fromSeed`，语义色作为补丁叠在
/// 派生结果上；同名键由它覆盖内置 spec 的值。
ThemeData buildAppTheme(
  Brightness brightness, {
  AppThemeColors colors = AppThemeColors.empty,
}) {
  // 三层装配：派生（`fromSeed` + `scheme` 覆盖）→ 内置 spec → 用户主题包。
  // 先合并成一张表再往下传，下游只有"一张覆盖表"这一种输入。
  final merged = _merge(builtinThemeColors(brightness), colors);
  final scheme = _schemeOf(brightness, merged);
  final base = ThemeData(
    colorScheme: scheme,
    // 显式给出页面底色：ThemeData 不同版本对"页面底取 surface 还是已废弃的
    // background"有过差异，写死能保证主题包给了纯黑就真的是纯黑。
    scaffoldBackgroundColor: scheme.surface,
    useMaterial3: true,
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );

  return base.copyWith(
    // 三档 `textTheme` 覆盖，让"没有显式写 fontSize"的默认文本也落进五档：
    // bodySmall 12→11.5、labelSmall 11→11.5、labelMedium 12→12.5。
    // 其余四档（bodyMedium 14 / labelLarge 14 / titleSmall 14 / titleMedium 16）
    // 本来就是目标值，不动——动它们等于把 ListTile、Button、AppBar 的默认
    // 尺寸一起改掉，影响面远大于收益。
    textTheme: _textThemeOf(base.textTheme),
    extensions: <ThemeExtension<dynamic>>[
      AppPalette.fromScheme(scheme).overrideWith(merged),
    ],
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
  );
}

/// 「内置 → 主题包」的合并：同名键由后者胜出。
///
/// 只做一次 Map 展开，发生在 `ThemeData` 构建期；渲染路径看不到"哪一层"。
AppThemeColors _merge(AppThemeColors base, AppThemeColors overrides) {
  if (overrides.isEmpty) {
    return base;
  }
  if (base.isEmpty) {
    return overrides;
  }
  return AppThemeColors(<String, Color>{
    ...base.values,
    ...overrides.values,
  });
}

TextTheme _textThemeOf(TextTheme base) {
  return base.copyWith(
    bodySmall: base.bodySmall?.copyWith(fontSize: AppFontSize.sm),
    labelSmall: base.labelSmall?.copyWith(fontSize: AppFontSize.sm),
    labelMedium: base.labelMedium?.copyWith(fontSize: AppFontSize.md),
  );
}

/// 先按种子色派生整套色阶，再叠上主题包对 `scheme.*` 的覆盖。
///
/// 顺序不能反：`AppPalette` 的文字灰阶是从 `onSurface` / `onSurfaceVariant`
/// 派生的，先 `copyWith` 再派生才能保证"页面变纯黑了，正文也跟着变"。
/// 未被覆盖的角色（`secondary` / `tertiary` / `error` …）仍由种子色决定。
ColorScheme _schemeOf(Brightness brightness, AppThemeColors colors) {
  final base = ColorScheme.fromSeed(
    seedColor: colors.seed ?? AppColors.seed,
    brightness: brightness,
  );
  if (colors.isEmpty) {
    return base;
  }

  return base.copyWith(
    primary: colors['scheme.primary'],
    onPrimary: colors['scheme.on_primary'],
    primaryContainer: colors['scheme.primary_container'],
    onPrimaryContainer: colors['scheme.on_primary_container'],
    surface: colors['scheme.surface'],
    surfaceContainerLowest: colors['scheme.surface_container_lowest'],
    surfaceContainerLow: colors['scheme.surface_container_low'],
    surfaceContainer: colors['scheme.surface_container'],
    surfaceContainerHigh: colors['scheme.surface_container_high'],
    surfaceContainerHighest: colors['scheme.surface_container_highest'],
    onSurface: colors['scheme.on_surface'],
    onSurfaceVariant: colors['scheme.on_surface_variant'],
    outline: colors['scheme.outline'],
    outlineVariant: colors['scheme.outline_variant'],
  );
}
