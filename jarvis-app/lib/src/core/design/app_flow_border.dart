import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 输入面板「等待首个 token」时的霓虹流光口径。
///
/// 色序、描边与光晕尺寸、一圈时长、淡入淡出时长全部收在这里：组件只按
/// [gradient] 画，界面文件不出现色值、模糊半径或周期。否则改一次观感要翻组件，
/// 深/浅两套主题还得各猜一遍取值。
///
/// 它不并进 `AppPalette`：这组颜色不与明暗相关、不表达任何业务状态，
/// 只是这一处装饰动效的原料；装配成 ThemeExtension 会让 `copyWith` / `lerp`
/// 为一个装饰件多出四个无关字段。
abstract final class AppFlowBorder {
  /// 一圈色序，首尾同色让循环没有接缝。
  static const List<Color> colors = <Color>[
    AppColors.flowCyan,
    AppColors.flowBlue,
    AppColors.flowViolet,
    AppColors.flowPink,
    AppColors.flowRose,
    AppColors.flowOrange,
    AppColors.flowGreen,
    AppColors.flowCyan,
  ];

  /// 走完一圈的时间。
  ///
  /// 4 秒是"看得出在动、又不催人"的折中：再快像加载条，再慢会让人怀疑卡住了。
  static const Duration period = Duration(seconds: 4);

  /// 淡入 / 淡出时长。
  ///
  /// 首个 token 到达后要立刻把注意力让给正文，所以淡出比淡入更该短；
  /// 两者共用一个值是为了让"进 / 出"的手感一致。
  static const Duration fadeDuration = Duration(milliseconds: 280);

  /// 贴边主描边宽度。
  static const double strokeWidth = 2;

  /// 外侧光晕的描边宽度与模糊半径。
  static const double glowWidth = 6;
  static const double glowSigma = 8;

  /// 贴边亮边的模糊半径：比光晕紧一档，边缘才是"亮线"而不是一团雾。
  static const double edgeSigma = 3;

  /// 光晕透明度。浅色底上同色光晕容易发灰，压一档。
  static const double glowAlphaDark = 0.55;
  static const double glowAlphaLight = 0.32;

  /// 按圈数取渐变。
  ///
  /// [turns] 只增不减（由动画控制器推进），角度随之单调递增；Canvas 的 y 轴
  /// 向下，正角度在屏幕上就是顺时针——这就是"光带顺时针流动"的唯一来源，
  /// 不要另外用镜像或负角度去实现。
  ///
  /// [opacity] 必须乘进色板，不能只设 `Paint.color`：一旦 `Paint.shader` 生效，
  /// paint 的颜色 alpha 就不再参与取色。
  static SweepGradient gradient({required double turns, double opacity = 1}) {
    return SweepGradient(
      colors: <Color>[
        for (final color in colors) color.withValues(alpha: opacity),
      ],
      transform: GradientRotation(turns * 2 * math.pi),
    );
  }
}
