import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/ui/liquid_glass_nav.dart';
import 'narrow_tabs.dart';

/// 胶囊背板的「液态玻璃」实现：真 shader 折射，不是模糊 + 半透明。
///
/// 与旧的 `BackdropFilter(lens)` 的区别：
/// - 背景按**边缘曲率**折进来（中心位移小、靠近两端位移大），不是一个均匀放大；
/// - 边缘 1~2px 内有逐通道色散，顶部有镜面高光，上沿压暗、下沿反光（厚度）；
/// - 这些都由包里自带的 `.frag` 算，我们只给形状、染色与内容。
///
/// 开关关（[liquidGlassNavEnabled] 为 false）时返回 null，调用方继续走原来的
/// `BackdropFilter` 实现——A/B 与回退都靠这一处分支。
Widget? liquidGlassBackplate({
  required BuildContext context,
  required Widget child,
  GlassQuality quality = GlassQuality.premium,
}) {
  if (!liquidGlassNavEnabled) {
    return null;
  }

  final scheme = Theme.of(context).colorScheme;
  final dark = scheme.brightness == Brightness.dark;

  return GlassContainer(
    // 单块胶囊：自建渲染层，`settings` 才会生效（分组模式下逐个组件的设置被忽略）。
    useOwnLayer: true,
    // premium 走完整管线（纹理捕获 + 色散 + 边缘光）；非 Impeller 端包里会
    // 自动降到 standard。帧率不够时把这个参数改成 standard 即可。
    quality: quality,
    // 61 高、全圆角：圆角半径直接决定"水滴"的曲率，改高度要同步改这里。
    shape: const LiquidRoundedRectangle(borderRadius: kBottomNavHeight / 2),
    clipBehavior: Clip.antiAlias,
    // 阴影仍由调用方那层 `DecoratedBox` 画（一条 0.08 / blur 20 的轻投影），
    // 这里关掉包自带的，免得同一颗胶囊出现两层影子。
    settings: LiquidGlassSettings(
      shadowElevation: 0,
      shadow: const <BoxShadow>[],
      // 折射深度：越大边缘把背景"吸"得越狠。61 高的胶囊上，26 让边缘位移
      // 到 6pt 上下，中间几乎不动——这是"水珠"最关键的线索；再大，
      // 底下的卡片文字会被拖进导航文字里，读不清。
      thickness: 26,
      refractiveIndex: 1.4,
      // 霜化只留一点点：0 时底下文字会"复印"一份压在导航标签上；
      // 2 既保留位移的错位感，又让重影化开。
      blur: 2,
      // 色散只在边缘露一丝；0.03 约等于 2px 的暖冷分离。
      chromaticAberration: 0.03,
      lightIntensity: 0.6,
      specularSharpness: GlassSpecularSharpness.sharp,
      // 玻璃本身的染色：太透时底下卡片文字会和 10.5sp 标签叠在一起，
      // 太实又会把折射盖掉。0.16 / 0.12 是"看得出玻璃后面有东西、但读得清"
      // 的折中；调参时先动这一个，再动 blur。
      glassColor: scheme.surface.withValues(alpha: dark ? 0.16 : 0.12),
      // 深色下压一点饱和度，避免色散把暗部拉成脏色。
      saturation: dark ? 1.3 : 1.5,
    ),
    child: child,
  );
}
