import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/agent_menu.dart';
import '../shell/shell_dividers.dart';
import 'canvas_options.dart';

/// 控制条高度：比栏头（40）高一档，给三枚下拉与四枚开关留出上下各 9dp 的呼吸。
///
/// 不再高：这一条只是"演示开关"，占掉过多高度会让画布在中栏里显得局促。
const double kCanvasControlBarHeight = 44;

/// 下拉浮层宽度。定值而不是跟着触发器走——触发器只有几十 dp，
/// 跟着它会把「渐变流光」这类文案挤成省略号。
const double kCanvasMenuWidth = 168;

/// 控制条上的稳定 Key。文案会改，测试靠这些定位。
const Key kCanvasLinkStyleMenuKey = Key('canvas-link-style-menu');
const Key kCanvasEffectMenuKey = Key('canvas-effect-menu');
const Key kCanvasGridMenuKey = Key('canvas-grid-menu');
const Key kCanvasMinimapToggleKey = Key('canvas-minimap-toggle');
const Key kCanvasSnapToggleKey = Key('canvas-snap-toggle');
const Key kCanvasLodToggleKey = Key('canvas-lod-toggle');
const Key kCanvasStatsToggleKey = Key('canvas-stats-toggle');
const Key kCanvasExportKey = Key('canvas-export');

/// 画布演示控制条：三组互斥样式 + 四个能力开关 + 导出。
///
/// 纯展示组件：所有状态由页面持有，这里只把"点了哪一项"回传。
/// 下拉一律走 [AgentMenu]——`PopupMenuButton` / `showMenu` 在 `features/**` 里是禁止项。
class CanvasControlBar extends StatelessWidget {
  const CanvasControlBar({
    super.key,
    required this.linkStyle,
    required this.effect,
    required this.gridStyle,
    required this.minimapVisible,
    required this.snapEnabled,
    required this.lodEnabled,
    required this.statsVisible,
    required this.onLinkStyleChanged,
    required this.onEffectChanged,
    required this.onGridStyleChanged,
    required this.onMinimapToggled,
    required this.onSnapToggled,
    required this.onLodToggled,
    required this.onStatsToggled,
    required this.onExport,
  });

  final CanvasLinkStyle linkStyle;
  final CanvasEffect effect;
  final CanvasGridStyle gridStyle;
  final bool minimapVisible;
  final bool snapEnabled;
  final bool lodEnabled;
  final bool statsVisible;
  final ValueChanged<CanvasLinkStyle> onLinkStyleChanged;
  final ValueChanged<CanvasEffect> onEffectChanged;
  final ValueChanged<CanvasGridStyle> onGridStyleChanged;
  final VoidCallback onMinimapToggled;
  final VoidCallback onSnapToggled;
  final VoidCallback onLodToggled;
  final VoidCallback onStatsToggled;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: kCanvasControlBarHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: shellDividerColor(scheme))),
      ),
      // 窄屏放不下时横向滚，不换行、不压缩：胶囊一旦被压窄，
      // 文案就成了省略号，四枚开关看起来像同一件事。
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: <Widget>[
            _menuPill<CanvasLinkStyle>(
              key: kCanvasLinkStyleMenuKey,
              label: '连线',
              current: linkStyle.label,
              values: CanvasLinkStyle.values,
              labelOf: (value) => value.label,
              selected: linkStyle,
              onSelected: onLinkStyleChanged,
              itemKeyOf: (value) => Key('canvas-link-style-${value.name}'),
            ),
            const SizedBox(width: 6),
            _menuPill<CanvasEffect>(
              key: kCanvasEffectMenuKey,
              label: '动效',
              current: effect.label,
              values: CanvasEffect.values,
              labelOf: (value) => value.label,
              selected: effect,
              onSelected: onEffectChanged,
              itemKeyOf: (value) => Key('canvas-effect-${value.name}'),
            ),
            const SizedBox(width: 6),
            _menuPill<CanvasGridStyle>(
              key: kCanvasGridMenuKey,
              label: '网格',
              current: gridStyle.label,
              values: CanvasGridStyle.values,
              labelOf: (value) => value.label,
              selected: gridStyle,
              onSelected: onGridStyleChanged,
              itemKeyOf: (value) => Key('canvas-grid-${value.name}'),
            ),
            const _BarDivider(),
            _CanvasTogglePill(
              key: kCanvasMinimapToggleKey,
              label: '小地图',
              selected: minimapVisible,
              onTap: onMinimapToggled,
            ),
            const SizedBox(width: 6),
            _CanvasTogglePill(
              key: kCanvasSnapToggleKey,
              label: '吸附',
              selected: snapEnabled,
              onTap: onSnapToggled,
            ),
            const SizedBox(width: 6),
            _CanvasTogglePill(
              key: kCanvasLodToggleKey,
              label: 'LOD',
              selected: lodEnabled,
              onTap: onLodToggled,
            ),
            const SizedBox(width: 6),
            _CanvasTogglePill(
              key: kCanvasStatsToggleKey,
              label: '统计',
              selected: statsVisible,
              onTap: onStatsToggled,
            ),
            const _BarDivider(),
            _CanvasActionPill(
              key: kCanvasExportKey,
              icon: Icons.data_object_outlined,
              label: '导出 JSON',
              onTap: onExport,
            ),
          ],
        ),
      ),
    );
  }

  /// 一枚下拉胶囊：左侧说明"这选的是什么"，右侧给当前值 + 折角箭头。
  ///
  /// 触发器由 [AgentMenu] 自己接管点击（默认 `triggerHandlesTap: true`），
  /// 所以这里只画外观，不再包一层手势——否则一次点击会既开又关。
  Widget _menuPill<T>({
    required Key key,
    required String label,
    required String current,
    required List<T> values,
    required String Function(T value) labelOf,
    required T selected,
    required ValueChanged<T> onSelected,
    required Key Function(T value) itemKeyOf,
  }) {
    return AgentMenu<T>(
      key: key,
      width: kCanvasMenuWidth,
      groups: <AgentMenuGroup<T>>[
        AgentMenuGroup<T>(
          items: <AgentMenuItem<T>>[
            for (final value in values)
              AgentMenuItem<T>(
                key: itemKeyOf(value),
                value: value,
                label: labelOf(value),
                selected: value == selected,
              ),
          ],
        ),
      ],
      onSelected: onSelected,
      builder: (context, controller, open, hovering) => _PillFrame(
        active: open,
        hovering: hovering,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: _pillLabelStyle(context)),
            const SizedBox(width: 6),
            Text(current, style: _pillValueStyle(context)),
            const SizedBox(width: 2),
            AgentMenuChevron(open: open, size: 12),
          ],
        ),
      ),
    );
  }

  TextStyle? _pillLabelStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontSize: AppFontSize.sm,
        height: AppLineHeight.tight,
        color: AppPalette.of(context).text.control,
      );

  TextStyle? _pillValueStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontSize: AppFontSize.sm,
        height: AppLineHeight.tight,
        color: AppPalette.of(context).text.primary,
      );
}

/// 下拉与开关共用的胶囊外壳。
///
/// 悬停 / 展开只换底色、不改内边距：一改内边距，鼠标扫过时整排控件会横向抖动。
class _PillFrame extends StatelessWidget {
  const _PillFrame({
    required this.child,
    this.active = false,
    this.hovering = false,
  });

  final Widget child;
  final bool active;
  final bool hovering;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlighted = active || hovering;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        // 选中是主色 12% 底，悬停是中性灰：两种状态说的事不一样——
        // 一个"这个开关开着"，一个"鼠标在这里"。
        color: active
            ? scheme.primary.withValues(alpha: 0.12)
            : highlighted
            ? scheme.surfaceContainerHighest.withValues(
                alpha: AgentMenuStyle.triggerHighlightAlpha,
              )
            : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Center(widthFactor: 1, child: child),
    );
  }
}

/// 开关胶囊：选中用主色文字 + 主色淡底，未选中用次级灰文字。
class _CanvasTogglePill extends StatefulWidget {
  const _CanvasTogglePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CanvasTogglePill> createState() => _CanvasTogglePillState();
}

class _CanvasTogglePillState extends State<_CanvasTogglePill> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: _PillFrame(
          active: widget.selected,
          hovering: _hovering,
          child: Text(
            widget.label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: AppFontSize.sm,
              height: AppLineHeight.tight,
              color: widget.selected ? scheme.primary : palette.text.secondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 行尾动作（导出）：只有悬停底，没有选中态。
class _CanvasActionPill extends StatefulWidget {
  const _CanvasActionPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_CanvasActionPill> createState() => _CanvasActionPillState();
}

class _CanvasActionPillState extends State<_CanvasActionPill> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: _PillFrame(
          hovering: _hovering,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(widget.icon, size: 13, color: palette.text.secondary),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: AppFontSize.sm,
                  height: AppLineHeight.tight,
                  color: palette.text.secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 组与组之间的竖线：12dp 上下留白 + 1dp 宽，视觉上把"样式"和"能力"分开。
class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Container(
        width: 1,
        height: 16,
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
    );
  }
}
