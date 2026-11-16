import 'package:vyuh_node_flow/vyuh_node_flow.dart';

/// 控制条上的三组互斥选项。
///
/// 选项值直接指向库里的样式对象，页面不自己做映射：换实现只改这一个文件，
/// 主题派生与控制条两边都不会漏。
enum CanvasLinkStyle {
  bezier('曲线', ConnectionStyles.bezier),
  smoothstep('圆角折线', ConnectionStyles.smoothstep),
  step('直角折线', ConnectionStyles.step),
  straight('直线', ConnectionStyles.straight);

  const CanvasLinkStyle(this.label, this.style);

  final String label;
  final ConnectionStyle style;
}

/// 连线动效。`none` 是真的不带动效——[ConnectionTheme.copyWith] 的 null 表示
/// "保持原值"，所以主题那边必须整份重建才能关得掉（见 `canvasThemeOf`）。
enum CanvasEffect {
  none('无'),
  flowingDash('流动虚线'),
  particles('粒子'),
  pulse('脉冲'),
  gradientFlow('渐变流光');

  const CanvasEffect(this.label);

  final String label;

  /// 库里预制的效果实例，`none` 给 null。
  ///
  /// 不用 `const` 枚举字段：`ConnectionEffects.xxx` 是 `static final`（内部含
  /// 可变粒子配置），塞不进 const 构造。
  ConnectionEffect? get effect => switch (this) {
    CanvasEffect.none => null,
    CanvasEffect.flowingDash => ConnectionEffects.flowingDash,
    CanvasEffect.particles => ConnectionEffects.particlesArrow,
    CanvasEffect.pulse => ConnectionEffects.pulse,
    CanvasEffect.gradientFlow => ConnectionEffects.gradientFlow,
  };
}

/// 网格背景。
enum CanvasGridStyle {
  dots('点阵', GridStyles.dots),
  lines('线格', GridStyles.lines),
  cross('十字', GridStyles.cross),
  none('关闭', GridStyles.none);

  const CanvasGridStyle(this.label, this.style);

  final String label;
  final GridStyle style;
}
