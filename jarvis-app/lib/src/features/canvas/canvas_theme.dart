import 'package:flutter/material.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import 'canvas_options.dart';

/// 把应用的语义色接到画布组件上。
///
/// 只在 `NodeFlowTheme` 这一层做映射：节点卡片、连线、网格、选择框、端口全部
/// 由它统一给出，画布内部不再出现任何裸色值。明暗两套都以库自带的
/// `NodeFlowTheme.light/dark` 为基底——那些只用来填我们没覆盖的几何参数
/// （贝塞尔曲率、端口外延、命中容差），颜色一律换成 `scheme` / [AppPalette]。
///
/// 为什么连线主题是"整份重建"而不是 `copyWith`：`ConnectionTheme.copyWith` 的
/// `animationEffect` 用 null 表示"保持原值"，想关掉动效必须构造一个新实例。
NodeFlowTheme canvasThemeOf(
  BuildContext context, {
  required CanvasLinkStyle linkStyle,
  required CanvasEffect effect,
  required CanvasGridStyle gridStyle,
}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final palette = AppPalette.of(context);
  final dark = theme.brightness == Brightness.dark;
  final base = dark ? NodeFlowTheme.dark : NodeFlowTheme.light;

  final link = scheme.primary;
  // 0.7 是"看得清但不当成强调色"的一档：再淡在灰底画布上会虚，
  // 再浓就与选中态撞成同一种颜色，分不出"这条线被选中了"。
  final linkColor = link.withValues(alpha: dark ? 0.78 : 0.7);
  final bodyMedium = theme.textTheme.bodyMedium ?? const TextStyle();

  return base.copyWith(
    // 画布底比卡片再沉一档：节点是"浮在画布上的白卡片"，
    // 反过来（画布白、卡片灰）会让整张图看起来是凹进去的。
    backgroundColor: scheme.surfaceContainerLow,
    nodeTheme: base.nodeTheme.copyWith(
      backgroundColor: scheme.surface,
      // 选中只换描边，不换底色：底色一变整张卡片会像被点亮，
      // 在十来个节点里同时选两个就成了一堵发光的墙。
      selectedBackgroundColor: scheme.surface,
      highlightBackgroundColor: scheme.surfaceContainerHigh,
      borderColor: scheme.outlineVariant,
      selectedBorderColor: link,
      highlightBorderColor: scheme.outline,
      borderWidth: 1,
      selectedBorderWidth: 1.5,
      borderRadius: BorderRadius.circular(AppRadius.md),
      titleStyle: bodyMedium.copyWith(
        fontSize: AppFontSize.base,
        height: AppLineHeight.tight,
        fontWeight: AppWeight.medium,
        color: palette.text.primary,
      ),
      contentStyle: bodyMedium.copyWith(
        fontSize: AppFontSize.sm,
        height: AppLineHeight.normal,
        color: palette.text.tertiary,
      ),
    ),
    connectionTheme: _connectionThemeOf(
      base: base.connectionTheme,
      linkStyle: linkStyle,
      effect: effect,
      color: linkColor,
      selected: link,
    ),
    // 临时连线（正拖出来那根）用虚线，和已连好的实线区分开。
    temporaryConnectionTheme: _connectionThemeOf(
      base: base.connectionTheme,
      linkStyle: linkStyle,
      effect: effect,
      color: linkColor,
      selected: link,
      dashed: true,
    ),
    portTheme: base.portTheme.copyWith(
      // 10dp 圆点比库默认的 9 略大：触摸端也要够得着，
      // 而节点卡片只有 190×88，再大就盖住标题。
      size: const Size(10, 10),
      color: scheme.surface,
      connectedColor: link,
      highlightColor: link,
      highlightBorderColor: link,
      borderColor: scheme.outline,
      borderWidth: 1.5,
      shape: MarkerShapes.circle,
      labelTextStyle: bodyMedium.copyWith(
        fontSize: AppFontSize.xs,
        height: AppLineHeight.tight,
        color: palette.text.tertiary,
      ),
    ),
    labelTheme: base.labelTheme.copyWith(
      textStyle: bodyMedium.copyWith(
        fontSize: AppFontSize.xs,
        height: AppLineHeight.tight,
        color: palette.text.secondary,
      ),
      backgroundColor: scheme.surface,
      border: Border.all(color: scheme.outlineVariant),
      borderRadius: BorderRadius.circular(AppRadius.xs),
    ),
    gridTheme: base.gridTheme.copyWith(
      color: scheme.outlineVariant,
      style: gridStyle.style,
      size: 24,
      thickness: 1,
    ),
    selectionTheme: base.selectionTheme.copyWith(
      // 10% 是"看得见但不遮住节点"的临界：再厚一档框选区里的卡片就糊了。
      color: link.withValues(alpha: 0.1),
      borderColor: link,
    ),
  );
}

ConnectionTheme _connectionThemeOf({
  required ConnectionTheme base,
  required CanvasLinkStyle linkStyle,
  required CanvasEffect effect,
  required Color color,
  required Color selected,
  bool dashed = false,
}) {
  return ConnectionTheme(
    style: linkStyle.style,
    color: color,
    selectedColor: selected,
    highlightColor: selected,
    highlightBorderColor: selected,
    strokeWidth: 2,
    selectedStrokeWidth: 2.5,
    dashPattern: dashed ? const <double>[6, 4] : null,
    startPoint: ConnectionEndPoint.none,
    // 终点给一个小三角：看向"数据往哪走"比看线本身更重要。
    endPoint: ConnectionEndPoint.triangle,
    endpointColor: color,
    endpointBorderColor: color,
    endpointBorderWidth: 0,
    animationEffect: effect.effect,
    bezierCurvature: base.bezierCurvature,
    cornerRadius: base.cornerRadius,
    portExtension: base.portExtension,
    backEdgeGap: base.backEdgeGap,
    hitTolerance: base.hitTolerance,
  );
}
