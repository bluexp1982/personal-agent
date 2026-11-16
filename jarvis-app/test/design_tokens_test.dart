import 'dart:io';
import 'dart:math' as math;

import 'package:jarvis_app/src/core/design/app_builtin_themes.dart';
import 'package:jarvis_app/src/core/design/app_palette.dart';
import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设计 token 的守护测试。
///
/// 这套规则的价值不在于"今天对不对"，而在于"半年后还对不对"：
/// 字号、灰阶、等宽字体族、状态色在改造前分别散在 22 个文件里，
/// 每加一个界面就能多出一个 11.5 或 0.62——没有任何机制拦得住。
/// 这里把四件事变成可执行的约束：
/// 1. 裸字号必须落在五档（外加内容标题与展示型）；
/// 2. 弱化文字不许再用 `onSurfaceVariant` 叠 alpha（对比度随容器变）；
/// 3. 等宽字体族只许从 [AppMono] 取；
/// 4. 圆角 / 行高 / 字重 / 主色底白字只许从 [AppRadius]、[AppLineHeight]、
///    [AppWeight]、[AppColors.onAccent] 取（存量非标值已列白名单，不再新增）。
void main() {
  group('字号白名单', () {
    // 五档 UI 字阶 + 内容标题（18/20） + 展示型（22/24/36）。
    final allowed = <double>{
      AppFontSize.xs,
      AppFontSize.sm,
      AppFontSize.md,
      AppFontSize.base,
      AppFontSize.lg,
      AppFontSize.h2,
      AppFontSize.h1,
      AppFontSize.display,
      AppFontSize.displayLg,
      AppFontSize.displayXl,
    };

    test('lib 下不再出现白名单以外的字号', () {
      final offenders = <String>[];
      final pattern = RegExp(r'fontSize:\s*([0-9]+(?:\.[0-9]+)?)');

      for (final file in _dartFilesUnder('lib')) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          for (final match in pattern.allMatches(lines[i])) {
            final value = double.parse(match.group(1)!);
            if (!allowed.contains(value)) {
              offenders.add('${file.path}:${i + 1}  fontSize: $value');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            '这些字号不在五档里（10.5 / 11.5 / 12.5 / 14 / 16，'
            '内容标题 18 / 20，展示 22 / 24）。请改用 AppFontSize：\n'
            '${offenders.join('\n')}',
      );
    });

    test('等宽字体族只从 AppMono 取', () {
      final offenders = <String>[];
      final pattern = RegExp("fontFamily:\\s*'(Menlo|monospace)'");

      for (final file in _dartFilesUnder('lib')) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            '等宽字体族要带跨平台 fallback，统一走 AppMono / AppText.mono：\n'
            '${offenders.join('\n')}',
      );
    });

    test('弱化文字不再用 onSurfaceVariant 叠 alpha', () {
      final offenders = <String>[];
      final pattern = RegExp(r'onSurfaceVariant\.withValues\(\s*alpha:');

      for (final file in _dartFilesUnder('lib')) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (pattern.hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            '叠 alpha 的灰阶在不同容器底上对比度不同，改用 AppPalette.text 的四个实色档：\n'
            '${offenders.join('\n')}',
      );
    });

    // `.adaptive` 在 macOS / iOS 上落成 CupertinoSwitch，激活色是系统绿，
    // 与 `scheme.primary` 无关——设置页那个开关曾因此独自变成绿色。
    test('开关不用 .adaptive 分支', () {
      final offenders = <String>[];

      for (final file in _dartFilesUnder('lib')) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          // 注释里允许提到 `.adaptive`（代码里要说明为什么不用它）。
          if (line.startsWith('//')) {
            continue;
          }
          if (line.contains('SwitchListTile.adaptive')) {
            offenders.add('${file.path}:${i + 1}');
          }
        }
      }

      expect(
        offenders.isEmpty,
        isTrue,
        reason:
            '开关一律用普通 SwitchListTile / Switch，让颜色跟主题主色走：\n'
            '${offenders.join('\n')}',
      );
    });
  });

  test('强调色只从 AppPalette 取', () {
    // 这四格已经进了主题包（`accent.*`）：
    // 界面里再直读 AppColors，等于把它们又钉回内置的琥珀与靛蓝。
    final offenders = <String>[];
    final pattern = RegExp(
      r'AppColors\.(projectStart|projectEnd|sshStart|sshEnd)',
    );

    for (final file in _uiDartFiles()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) {
          continue;
        }
        if (pattern.hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '强调色的唯一入口是 `AppPalette.of(context)`：\n'
          '${offenders.join('\n')}',
    );
  });

  // 侧栏项目行的文件夹图标曾经单独读 `palette.icon.folderSelected`，换主题后
  // 会出现"卡片是主题色、图标还是另一种颜色"。现在它必须跟项目强调色同源。
  test('侧栏项目文件夹图标取项目强调色', () {
    final source = File(
      'lib/src/features/shell/project_icon.dart',
    ).readAsStringSync();

    expect(
      source.contains('palette.accent.projectStart'),
      isTrue,
      reason: '项目行的文件夹图标要与项目卡片 / 计数胶囊 / 导航选中态同一身份色',
    );
    expect(
      source.contains('palette.icon'),
      isFalse,
      reason: '图标色组已从 AppPalette 移除，界面不应再读它',
    );
  });

  group('尺寸与颜色 token 收口', () {
    // 0.5 / 2.5 不是"形状圆角"：一个是 1dp 分隔条的端点，一个是 11px 停止方块，
    // 吸附到六档会改变几何。只允许这两处存量，其余一律走 AppRadius。
    final legacyRadii = <double>{0.5, 2.5};
    final allowedRadii = <double>{
      AppRadius.xs,
      AppRadius.sm,
      AppRadius.md,
      AppRadius.lg,
      AppRadius.xl,
      AppRadius.pill,
      ...legacyRadii,
    };

    // 终端的 1.35 也是一档（[AppLineHeight.terminal]）；Markdown 的排版行高
    // 已经收进 `message_markdown.dart` 的具名常量，不再以字面量出现。
    final allowedLineHeights = <double>{
      AppLineHeight.tight,
      AppLineHeight.code,
      AppLineHeight.normal,
      AppLineHeight.relaxed,
      AppLineHeight.terminal,
    };

    test('圆角只从 AppRadius 取', () {
      final offenders = <String>[];
      final pattern = RegExp(
        r'BorderRadius\.circular\(\s*([0-9]+(?:\.[0-9]+)?)\s*\)',
      );

      for (final file in _uiDartFiles()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          for (final match in pattern.allMatches(lines[i])) {
            final value = double.parse(match.group(1)!);
            if (!allowedRadii.contains(value)) {
              offenders.add('${file.path}:${i + 1}  circular($value)');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            '圆角只用 AppRadius（6 / 8 / 12 / 16 / 24 / 999）。'
            '不在六档里的值要么吸附，要么先补 token：\n'
            '${offenders.join('\n')}',
      );
    });

    test('行高只从 AppLineHeight 取', () {
      final offenders = <String>[];
      final pattern = RegExp(r'height:\s*(1\.[0-9]+)');

      for (final file in _uiDartFiles()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          for (final match in pattern.allMatches(lines[i])) {
            final value = double.parse(match.group(1)!);
            if (!allowedLineHeights.contains(value)) {
              offenders.add('${file.path}:${i + 1}  height: $value');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            '行高只用 AppLineHeight（1.2 / 1.45 / 1.5 / 1.6），'
            '刻意值 1.35 / 1.4 / 1.55 只给终端与 Markdown：\n'
            '${offenders.join('\n')}',
      );
    });

    test('字重、字距与主色底文字只从 token 取', () {
      final offenders = <String>[];
      final patterns = <RegExp, String>{
        RegExp(r'fontWeight:\s*FontWeight\.w[0-9]00'): '改用 AppWeight',
        RegExp(r'letterSpacing:\s*[0-9.]'): '改用 AppLetterSpacing',
        RegExp(r'\bColors\.white\b'):
            '改用 AppColors.onAccent / palette.text.onAccent',
      };

      for (final file in _uiDartFiles()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          for (final entry in patterns.entries) {
            if (entry.key.hasMatch(lines[i])) {
              offenders.add('${file.path}:${i + 1}  ${entry.value}');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: '裸字重与 Colors.white：\n${offenders.join('\n')}',
      );
    });
  });

  group('主题装配', () {
    test('明暗两套都注册了 AppPalette', () {
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(brightness);
        expect(
          theme.extension<AppPalette>(),
          isNotNull,
          reason: '${brightness.name} 主题缺少 AppPalette',
        );
        expect(
          theme.textTheme.labelSmall?.fontSize,
          AppFontSize.sm,
          reason: 'labelSmall 应覆盖到 11.5，否则默认小字会掉回 11',
        );
        expect(theme.textTheme.bodySmall?.fontSize, AppFontSize.sm);
        expect(theme.textTheme.labelMedium?.fontSize, AppFontSize.md);
      }
    });
  });

  group('对比度', () {
    const backgrounds = <String, Color>{
      'surface': Color(0xFFF8F9FF),
      'surfaceContainerLowest': Color(0xFFFFFFFF),
      'surfaceContainerHighest': Color(0xFFE1E2E8),
    };
    const darkBackgrounds = <String, Color>{
      'surface': Color(0xFF111418),
      'surfaceContainerLowest': Color(0xFF0B0E13),
      'surfaceContainerHighest': Color(0xFF32353A),
    };

    test('浅色 primary / secondary 在三种底上都 ≥ 4.5:1', () {
      final text = AppPalette.forBrightness(Brightness.light).text;
      for (final entry in backgrounds.entries) {
        for (final pair in <String, Color>{
          'primary': text.primary,
          'secondary': text.secondary,
        }.entries) {
          expect(
            _contrast(pair.value, entry.value),
            greaterThanOrEqualTo(4.5),
            reason: '浅色 ${pair.key} 在 ${entry.key} 上对比度不足',
          );
        }
      }
    });

    // 浅色 tertiary 是需求方指定的例外（2026-11-01）：占位提示、时间戳这类
    // 文字要明显比正文淡，代价是对白底只有 2.03:1、对灰底 1.65:1。
    // 这里不再要求 4.5:1，改为锁死"值是什么"和"不能再淡"——
    // 断言仍然拦得住"顺手调淡一点"的改动。
    test('浅色 tertiary 固定为 #ADB2B9，且不再下探', () {
      final text = AppPalette.forBrightness(Brightness.light).text;
      expect(
        text.tertiary,
        const Color(0xFFADB2B9),
        reason: '浅色 tertiary 的口径由需求指定，深色仍是 #98A0AC，两侧不同步是有意的',
      );
      for (final entry in backgrounds.entries) {
        expect(
          _contrast(text.tertiary, entry.value),
          greaterThanOrEqualTo(1.6),
          reason: '浅色 tertiary 在 ${entry.key} 上已经淡到看不见',
        );
      }
    });

    // 控件入口色同样不在 4.5:1 之内（白底 4.03、灰底 3.12），
    // 但它落在输入栏白面板上，且参考的是外部客户端的控件行观感。
    // 下限卡在 3:1：再淡就低于"非文本图形"的最低识别线。
    test('浅色控件灰固定为 #7B7F83，且不低于 3:1', () {
      final text = AppPalette.forBrightness(Brightness.light).text;
      expect(text.control, const Color(0xFF7B7F83));
      for (final entry in backgrounds.entries) {
        expect(
          _contrast(text.control, entry.value),
          greaterThanOrEqualTo(3),
          reason: '浅色控件灰在 ${entry.key} 上已经低于可辨识下限',
        );
      }
    });

    test('深色四档文字在三种底上都 ≥ 4.5:1', () {
      final text = AppPalette.forBrightness(Brightness.dark).text;
      for (final entry in darkBackgrounds.entries) {
        for (final pair in <String, Color>{
          'primary': text.primary,
          'secondary': text.secondary,
          'tertiary': text.tertiary,
          'control': text.control,
        }.entries) {
          expect(
            _contrast(pair.value, entry.value),
            greaterThanOrEqualTo(4.5),
            reason: '深色 ${pair.key} 在 ${entry.key} 上对比度不足',
          );
        }
      }
    });

    test('状态色在页面底与自身 12% 胶囊底上都 ≥ 4.5:1', () {
      for (final brightness in Brightness.values) {
        final palette = AppPalette.forBrightness(brightness);
        final background = brightness == Brightness.light
            ? backgrounds['surface']!
            : darkBackgrounds['surface']!;
        final status = palette.status;

        final colors = <String, Color>{
          'success': status.success,
          'warning': status.warning,
          'danger': status.danger,
          'info': status.info,
          'neutral': status.neutral,
        };

        for (final entry in colors.entries) {
          expect(
            _contrast(entry.value, background),
            greaterThanOrEqualTo(4.5),
            reason: '${brightness.name} ${entry.key} 在页面底上对比度不足',
          );
          expect(
            _contrast(
              entry.value,
              status.surfaceOf(entry.value).over(background),
            ),
            greaterThanOrEqualTo(4.5),
            reason: '${brightness.name} ${entry.key} 在自己的胶囊底上对比度不足',
          );
        }
      }
    });
  });

  group('语法高亮配色', () {
    // 代码在三种容器底上都会出现：文件预览的页面底、消息代码块的浅/深底、
    // 以及极端情况下的 surfaceContainerHighest。三档都要过 4.5:1——
    // 语法色不是装饰，`const` 与 `return` 读错就是读错代码。
    const lightCodeBackground = Color(0xFFF3F4F6);
    const darkCodeBackground = Color(0xFF24272D);
    const lightBackgrounds = <String, Color>{
      'surface': Color(0xFFF8F9FF),
      'surfaceContainerHighest': Color(0xFFE1E2E8),
      'codeBackground': lightCodeBackground,
    };
    const darkBackgrounds = <String, Color>{
      'surface': Color(0xFF111418),
      'surfaceContainerHighest': Color(0xFF32353A),
      'codeBackground': darkCodeBackground,
    };

    Map<String, Color> paletteOf(AppSyntaxColors colors) => <String, Color>{
      'keyword': colors.keyword,
      'string': colors.string,
      'number': colors.number,
      'comment': colors.comment,
      'function': colors.function,
      'type': colors.type,
      'variable': colors.variable,
      'property': colors.property,
      'operator': colors.operator,
      'meta': colors.meta,
      'invalid': colors.invalid,
    };

    test('明暗两套的十一类 token 在三种底上都 ≥ 4.5:1', () {
      for (final brightness in Brightness.values) {
        final syntax = AppPalette.forBrightness(brightness).syntax;
        final backgrounds = brightness == Brightness.light
            ? lightBackgrounds
            : darkBackgrounds;
        for (final entry in paletteOf(syntax).entries) {
          for (final background in backgrounds.entries) {
            expect(
              _contrast(entry.value, background.value),
              greaterThanOrEqualTo(4.5),
              reason:
                  '${brightness.name} 语法色 ${entry.key} 在 ${background.key} 上对比度不足',
            );
          }
        }
      }
    });

    test('同一类 token 在明暗两套里都是不同色值', () {
      // 两套共用一份常量会让深色主题下的注释淡到看不见；
      // 这里只拦"忘了给某一套单独取值"的低级错误。
      final light = paletteOf(AppPalette.forBrightness(Brightness.light).syntax);
      final dark = paletteOf(AppPalette.forBrightness(Brightness.dark).syntax);
      for (final key in light.keys) {
        expect(
          light[key],
          isNot(dark[key]),
          reason: '语法色 $key 在明暗两套里取了同一个值',
        );
      }
    });
  });

  group('token 取值', () {
    test('五档字阶严格递增且互不相同', () {
      const tiers = <double>[
        AppFontSize.xs,
        AppFontSize.sm,
        AppFontSize.md,
        AppFontSize.base,
        AppFontSize.lg,
      ];
      for (var i = 1; i < tiers.length; i++) {
        expect(
          tiers[i],
          greaterThan(tiers[i - 1]),
          reason: '字阶必须单调递增，否则"大一档"没有意义',
        );
      }
      expect(tiers.toSet().length, tiers.length);
    });

    test('强调色由内置 spec 分浅/深两组给出', () {
      final light = AppPalette.forBrightness(Brightness.light).accent;
      final dark = AppPalette.forBrightness(Brightness.dark).accent;
      final lightSpec = builtinThemeColors(Brightness.light);
      final darkSpec = builtinThemeColors(Brightness.dark);

      expect(light.projectStart, lightSpec['accent.project_start']);
      expect(light.sshStart, lightSpec['accent.ssh_start']);
      expect(dark.projectStart, darkSpec['accent.project_start']);
      expect(dark.sshStart, darkSpec['accent.ssh_start']);
      expect(
        light.projectStart,
        isNot(dark.projectStart),
        reason: '强调色会被当文字/图标色用，明暗必须各有一档',
      );
    });

    test('内置强调色在页面底与自身 12% 淡底上都 ≥4.5:1', () {
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(brightness);
        final palette = theme.extension<AppPalette>()!;
        final surface = theme.colorScheme.surface;
        final accent = palette.accent;

        for (final color in <Color>[
          accent.projectStart,
          accent.projectTint,
          accent.sshStart,
        ]) {
          expect(
            _contrast(color, surface),
            greaterThanOrEqualTo(4.5),
            reason: '$brightness 的强调色对页面底不够：$color',
          );
          expect(
            _contrast(color, palette.status.surfaceOf(color).over(surface)),
            greaterThanOrEqualTo(4.5),
            reason: '$brightness 的强调色落在自身 12% 淡底上不够：$color',
          );
        }
      }
    });

    test('强调色的渐变与 tint 由端点色派生', () {
      final palette = AppPalette.forBrightness(Brightness.light);
      final accent = palette.accent;

      expect(accent.projectGradient.colors, <Color>[
        accent.projectStart,
        accent.projectEnd,
      ]);
      expect(accent.sshGradient.colors, <Color>[
        accent.sshStart,
        accent.sshEnd,
      ]);
      expect(
        accent.projectTint,
        Color.lerp(accent.projectStart, accent.projectEnd, 0.35),
      );
      expect(accent.sshTint, Color.lerp(accent.sshStart, accent.sshEnd, 0.35));
    });

    test('内置两套都不铺顶部渐变：topTint 全透明', () {
      for (final brightness in Brightness.values) {
        expect(
          AppPalette.forBrightness(brightness).surface.topTint.a,
          0,
          reason: '$brightness 内置主题应该是纯色底',
        );
      }
    });
  });
}

/// WCAG 2.1 相对亮度对比度。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

extension on Color {
  /// 把带 alpha 的颜色合成到不透明底上，得到最终看到的颜色。
  Color over(Color background) => Color.alphaBlend(this, background);
}

Iterable<File> _dartFilesUnder(String path) {
  final dir = Directory(path);
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));
}

/// 界面代码：`core/design` 是 token 自身的定义处，不该被"只用 token"约束。
Iterable<File> _uiDartFiles() =>
    _dartFilesUnder('lib').where((file) => !file.path.contains('core/design/'));
