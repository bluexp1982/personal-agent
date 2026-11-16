import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import 'call_icons.dart';

/// 头像外环的标准边长。
const double _kRingSize = 208;

/// 环心的标准边长（原型 160 / 208）。
const double _kRingCoreRatio = 160 / 208;

/// 矮屏时环能缩到的最小边长。
const double _kRingMinSize = 128;

/// 两圈同心的间距。
const double _kRingInset = 16;

/// 「说话或点击打断」那枚停止钮的边长。
const double _kStopSize = 34;

/// 控制键边长。
const double _kControlSize = 58;

/// 控制键与情景胶囊共用的磨砂量。建一次复用：静止页反复分配原生资源没有意义。
final ImageFilter _callBlur = ImageFilter.blur(sigmaX: 10, sigmaY: 10);

/// 「选择情景」胶囊的 Key：测试用它量胶囊是否落在页头中线上。
const Key kCallScenarioPillKey = Key('call-scenario-pill');

/// 「实时通话」页（占位）。
///
/// 通话能力还没接入：这里只按手机端原型把界面铺出来——页头（标题 + 选择情景 +
/// 字幕）、双层强调色头像环与计时、打断提示、四枚控制键、AI 生成声明。
/// 所有按钮都是空回调，点了只有水波纹，不启动麦克风、不计时、不出字幕；
/// 接入真实控制器时把 `_CallControl.onTap` 与计时文案换掉即可，布局不用动。
class CallPage extends StatelessWidget {
  const CallPage({super.key, this.bottomInset = 0, this.topInset = 0});

  /// 底部为悬浮胶囊导航留出的高度。
  final double bottomInset;

  /// 顶部为页头留出的高度：窄屏一级标签页的 body 延伸到了页头之后。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);

    return AppPageScaffold(
      // 窄屏一级标签：body 铺到页头之后，页头那层虚化带才有内容可糊。
      frostTop: topInset > 0,
      appBar: MobileAppBar(
        // 一级标签页，没有可返回的上一页。
        showBack: false,
        // 标题区铺满整宽：中间那枚胶囊才能落在页宽中线上。
        titleSpacing: 0,
        titleWidget: SizedBox(
          height: kMobileTopBarButtonSize,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: kMobileTopBarSideInset,
                  ),
                  child: Text(
                    '实时通话',
                    style: mobileTopBarTitleStyle(context),
                  ),
                ),
              ),
              // 「选择情景」独立居中：标题与字幕各在两端，不影响它的落点。
              _ScenarioPill(palette: palette, text: text, scheme: scheme),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(
                    right: kMobileTopBarEndInset,
                  ),
                  child: MobileTopBarButton(
                    tooltip: '字幕',
                    onPressed: () {},
                    child: Text(
                      '字',
                      style: text.row.copyWith(
                        fontSize: AppFontSize.md,
                        fontWeight: AppWeight.semiBold,
                        color: palette.text.secondary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 页头那一段不算可用高度：body 延伸到页头之后，环按剩下那部分收缩。
          final usable = math.max(0.0, constraints.maxHeight - topInset);
          // 矮屏按可用高度收缩，别让环把控制键挤出屏幕。
          final ring = math
              .min(_kRingSize, usable * 0.32)
              .clamp(_kRingMinSize, _kRingSize)
              .toDouble();

          return CustomScrollView(
            slivers: <Widget>[
              SliverFillRemaining(
                // 内容不足一屏时垂直居中；矮屏时整页可滚，页脚不会压在胶囊上。
                hasScrollBody: false,
                child: Column(
                  children: <Widget>[
                    // 首项让出页头：静止时内容与其余四页落在同一条基线。
                    SizedBox(height: topInset),
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              _AvatarRing(size: ring, scheme: scheme),
                              const SizedBox(height: 26),
                              _Identity(text: text, palette: palette),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _InterruptHint(palette: palette, text: text, scheme: scheme),
                    const SizedBox(height: 18),
                    const _Controls(),
                    const SizedBox(height: 12),
                    Text(
                      '内容由 AI 生成',
                      style: text.meta.copyWith(
                        fontSize: AppFontSize.xs,
                        letterSpacing: AppLetterSpacing.tight,
                      ),
                    ),
                    SizedBox(height: bottomInset),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 页头里的「选择情景」胶囊：四宫格 + 文案 + 下箭头。
///
/// 情景选择还没做：这里只保留原型的形态与命中区，点击无行为。
class _ScenarioPill extends StatelessWidget {
  const _ScenarioPill({
    required this.palette,
    required this.text,
    required this.scheme,
  });

  final AppPalette palette;
  final AppText text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.pill);

    return ClipRRect(
      key: kCallScenarioPillKey,
      borderRadius: radius,
      child: BackdropFilter(
        filter: _callBlur,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.52),
            borderRadius: radius,
            border: Border.all(
              color: palette.accent.projectStart.withValues(alpha: 0.18),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () {},
              borderRadius: radius,
              child: SizedBox(
                height: 34,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      CallIcon(
                        glyph: CallGlyph.scenario,
                        color: palette.text.secondary,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '选择情景',
                        style: text.rowSecondary.copyWith(
                          fontSize: AppFontSize.md,
                          fontWeight: AppWeight.medium,
                          letterSpacing: AppLetterSpacing.tight,
                        ),
                      ),
                      const SizedBox(width: 6),
                      CallIcon(
                        glyph: CallGlyph.chevron,
                        color: palette.text.tertiary,
                        size: 14,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 双层强调色圆环 + 环心头像。
///
/// 环心用原型里的那张对话头像（`assets/call/avatar.png`，圆形裁切铺满）；
/// 资源缺失时退回项目星芒，不至于剩一个空圆环。
class _AvatarRing extends StatelessWidget {
  const _AvatarRing({required this.size, required this.scheme});

  final double size;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final core = size * _kRingCoreRatio;
    final accent = AppPalette.of(context).accent;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: accent.projectStart.withValues(alpha: 0.22),
                ),
              ),
            ),
          ),
          Positioned.fill(
            left: _kRingInset,
            top: _kRingInset,
            right: _kRingInset,
            bottom: _kRingInset,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: accent.projectStart.withValues(alpha: 0.30),
                ),
              ),
            ),
          ),
          Container(
            width: core,
            height: core,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surface.withValues(alpha: 0.70),
              border: Border.all(
                color: accent.projectStart.withValues(alpha: 0.26),
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.12),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            // 图片内缩 1px：描边画在装饰层的最外缘，图片不内缩会把它盖掉。
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: ClipOval(
                child: Image.asset(
                  'assets/call/avatar.png',
                  fit: BoxFit.cover,
                  // 头像只是装饰，名字就在下面：读屏不必再念一遍图片。
                  excludeFromSemantics: true,
                  // 资源缺失时退回项目星芒，总比一个空圆环好。
                  errorBuilder: (context, error, stack) => Center(
                    child: CallIcon(
                      glyph: CallGlyph.sparkle,
                      color: accent.projectStart,
                      size: core * 0.35,
                      strokeWidth: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 环下的身份行：名字 + 等宽计时。
class _Identity extends StatelessWidget {
  const _Identity({required this.text, required this.palette});

  final AppText text;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Jarvis',
          style: text.row.copyWith(fontWeight: AppWeight.semiBold),
        ),
        const SizedBox(height: 4),
        Text(
          '03:12',
          style: text
              .mono(size: AppFontSize.sm, color: palette.text.tertiary)
              .copyWith(letterSpacing: AppLetterSpacing.tight),
        ),
      ],
    );
  }
}

/// 打断区：圆形停止钮 + 一句提示。
class _InterruptHint extends StatelessWidget {
  const _InterruptHint({
    required this.palette,
    required this.text,
    required this.scheme,
  });

  final AppPalette palette;
  final AppText text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipOval(
          child: BackdropFilter(
            filter: _callBlur,
            child: Container(
              width: _kStopSize,
              height: _kStopSize,
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.60),
                border: Border.all(
                  color: palette.accent.projectStart.withValues(alpha: 0.18),
                ),
              ),
              child: Center(
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: palette.text.tertiary,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '说话或点击打断',
          style: text.meta.copyWith(
            fontSize: AppFontSize.md,
            color: palette.text.secondary,
            letterSpacing: AppLetterSpacing.tight,
          ),
        ),
      ],
    );
  }
}

/// 四枚控制键：麦克风（选中）/ 静音 / 关摄像头 / 挂断。
class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const _CallControl(
          glyph: CallGlyph.mic,
          label: '麦克风',
          tone: _ControlTone.active,
        ),
        const SizedBox(width: 14),
        const _CallControl(glyph: CallGlyph.micOff, label: '关闭麦克风'),
        const SizedBox(width: 14),
        const _CallControl(glyph: CallGlyph.cameraOff, label: '关闭摄像头'),
        const SizedBox(width: 14),
        const _CallControl(
          glyph: CallGlyph.hangUp,
          label: '挂断',
          tone: _ControlTone.danger,
          strokeWidth: 1.8,
        ),
      ],
    );
  }
}

/// 控制键的三套配色。
enum _ControlTone { normal, active, danger }

class _CallControl extends StatelessWidget {
  const _CallControl({
    required this.glyph,
    required this.label,
    this.tone = _ControlTone.normal,
    this.strokeWidth = 1.6,
  });

  final CallGlyph glyph;
  final String label;
  final _ControlTone tone;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final accent = palette.accent;
    final danger = palette.status.danger;

    final fill = switch (tone) {
      _ControlTone.active => null,
      _ControlTone.danger => palette.status.surfaceOf(danger),
      _ControlTone.normal => scheme.surface.withValues(alpha: 0.62),
    };
    final border = switch (tone) {
      _ControlTone.active => accent.projectStart.withValues(alpha: 0.35),
      _ControlTone.danger => palette.status.borderOf(danger),
      _ControlTone.normal => accent.projectStart.withValues(alpha: 0.18),
    };
    final iconColor = switch (tone) {
      _ControlTone.active => palette.text.onAccent,
      _ControlTone.danger => danger,
      _ControlTone.normal => palette.text.secondary,
    };
    final shadows = <BoxShadow>[
      if (tone == _ControlTone.active)
        BoxShadow(
          color: accent.projectStart.withValues(alpha: 0.30),
          blurRadius: 14,
          offset: const Offset(0, 4),
        )
      else if (tone == _ControlTone.normal)
        BoxShadow(
          color: scheme.shadow.withValues(alpha: 0.10),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
    ];

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: SizedBox(
          width: _kControlSize,
          height: _kControlSize,
          child: DecoratedBox(
            // 投影画在裁剪之外：放进 ClipOval 里会被圆形一并切掉。
            decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: shadows),
            child: ClipOval(
              child: BackdropFilter(
                filter: _callBlur,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // 选中态用项目强调色渐变，与底部导航选中块同一套色。
                    color: fill,
                    gradient: tone == _ControlTone.active
                        ? accent.projectGradient
                        : null,
                    border: Border.all(color: border),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      // 占位：接入通话控制器前点击只给水波纹。
                      onTap: () {},
                      customBorder: const CircleBorder(),
                      child: Center(
                        child: CallIcon(
                          glyph: glyph,
                          color: iconColor,
                          strokeWidth: strokeWidth,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
