import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'liquid_glass_nav.dart';

/// 页头玻璃的形状：单枚是圆，并排按钮合并后是胶囊。
enum MobileTopBarGlassShape { circle, capsule }

/// 页头按钮的玻璃背板当前是否启用。
///
/// 与底部导航共用同一个开关（[liquidGlassNavEnabled]）：关掉时调用方继续走
/// 旧的 `BackdropFilter` 路径，几何与外观逐像素不变，A/B 与回退都靠这一处。
bool get mobileTopBarGlassEnabled => liquidGlassNavEnabled;

/// 页头圆钮 / 胶囊的真折射玻璃背板。
///
/// 与旧的 `BackdropFilter(sigma 10)` 的区别：背景按**边缘曲率**折进来（中心位移
/// 小、靠近边缘位移大），边缘 1~2px 内有逐通道色散与镜面高光——这些由包里自带
/// 的 `.frag` 算，我们只给形状、染色与内容。只换材质，不动尺寸与内容层。
///
/// 开关关闭（[mobileTopBarGlassEnabled] 为 false）时返回 null，调用方回退旧路径。
///
/// [tint] 由调用方从 `_glassOf` 传入（那套配色本身又从 `core/design` 派生），
/// 这里只按亮/暗与深浅主题覆盖透明度：太透时 18dp 图标会与底下的卡片文字叠在
/// 一起，太实又会把折射盖掉。
Widget? mobileTopBarGlassBackplate({
  required BuildContext context,
  required Widget child,
  required MobileTopBarGlassShape shape,
  required double height,
  required Color tint,
  bool dark = false,
  GlassQuality quality = GlassQuality.premium,
}) {
  if (!mobileTopBarGlassEnabled) {
    return null;
  }

  final scheme = Theme.of(context).colorScheme;
  final isDark = scheme.brightness == Brightness.dark;

  return GlassContainer(
    // 单块背板：自建渲染层，`settings` 才会生效（分组模式下逐个组件的设置被
    // 忽略）。按钮组也只在整组上建一层，组内每一格不能再各建一层，否则胶囊
    // 中间会出现两条折射边缘。
    useOwnLayer: true,
    // 页头是静态区域，走完整管线（纹理捕获 + 色散 + 边缘光）；非 Impeller 端
    // 包里会自动降到 standard。
    quality: quality,
    shape: switch (shape) {
      MobileTopBarGlassShape.circle => const LiquidOval(),
      // 胶囊的圆角半径直接决定"水滴"的曲率，必须跟高度绑在一起。
      MobileTopBarGlassShape.capsule => LiquidRoundedRectangle(
        borderRadius: height / 2,
      ),
    },
    clipBehavior: Clip.antiAlias,
    settings: LiquidGlassSettings(
      // 页头按钮原本没有投影，这里关掉包自带的，免得凭空多出一圈暗边。
      shadowElevation: 0,
      shadow: const <BoxShadow>[],
      // 折射深度按高度取比例：38 → 约 14、30 → 约 11。再大，18dp 图标会被
      // 边缘位移拖糊；再小，就只剩一层均匀的雾。
      thickness: height * 0.36,
      refractiveIndex: 1.38,
      // 霜化只留一点点：0 时底下文字会"复印"一份压在图标上；1.4~1.8 既保留
      // 位移的错位感，又让重影化开。
      blur: height >= 38 ? 1.8 : 1.4,
      // 色散只在边缘露一丝（约 1~2px 的暖冷分离）。
      chromaticAberration: 0.022,
      lightIntensity: 0.55,
      specularSharpness: GlassSpecularSharpness.sharp,
      // 玻璃本身的染色：黑底查看器（[dark]）用淡淡的白色磨砂，否则沿用页头那
      // 层暖白（深色主题需要更高一点的不透明度，不然会糊成一层雾）。
      glassColor: tint.withValues(
        alpha: dark ? 0.10 : (isDark ? 0.26 : 0.20),
      ),
      // 深色下压一点饱和度，避免色散把暗部拉成脏色。
      saturation: isDark ? 1.3 : 1.45,
    ),
    child: child,
  );
}
