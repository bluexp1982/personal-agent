import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 带染色的深色调色板：内置主题不染色（`topTint` 全透明），渐变会退化成纯色，
/// 量不出"顶部带是否与背景同色"这件事。
AppPalette _tintedPalette(ColorScheme scheme) {
  return AppPalette.fromScheme(scheme).copyWith(
    surface: const AppSurfaceColors(topTint: Color(0xFFFFD400)),
  );
}

void main() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.dark,
  );
  final palette = _tintedPalette(scheme);

  test('fraction 为 0 时等于渐变顶部色', () {
    expect(
      appSurfaceColorAt(palette, scheme, 0),
      appSurfaceTopColor(palette, scheme),
    );
  });

  test('到达收敛点及以下都等于页面底色', () {
    expect(appSurfaceColorAt(palette, scheme, kSurfaceTopTintStop), scheme.surface);
    expect(appSurfaceColorAt(palette, scheme, 0.9), scheme.surface);
  });

  test('随 fraction 增大单调变暗（插值方向不能写反）', () {
    final samples = <double>[0, 0.02, 0.06, 0.12, 0.2, 0.3, kSurfaceTopTintStop]
        .map((f) => appSurfaceColorAt(palette, scheme, f).computeLuminance())
        .toList();

    for (var i = 1; i < samples.length; i++) {
      expect(
        samples[i],
        lessThanOrEqualTo(samples[i - 1] + 1e-9),
        reason: '第 $i 个采样比前一个更亮：${samples[i - 1]} → ${samples[i]}',
      );
    }
    expect(samples.first, greaterThan(samples.last));
  });

  test('状态栏那一段（约 7% 窗高）明显比顶端暗，差值足够形成台阶', () {
    final top = appSurfaceColorAt(palette, scheme, 0);
    final atStatusBar = appSurfaceColorAt(palette, scheme, 0.07);

    // 实测：深色主题包下顶端 47、状态栏下沿 39，差 8 个亮度。
    // 这正是"用顶端色去盖带子上沿会抬出 2~3"的来源，也是本函数存在的理由。
    expect(top.computeLuminance(), greaterThan(atStatusBar.computeLuminance()));
  });

  test('不染色的调色板：任何比例都等于页面底色', () {
    final plain = AppPalette.fromScheme(scheme);

    for (final fraction in <double>[0, 0.1, 0.5, 1]) {
      expect(appSurfaceColorAt(plain, scheme, fraction), scheme.surface);
    }
  });
}
