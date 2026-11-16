import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/edge_fade.dart';
import 'narrow_tab_glass.dart';
import 'narrow_tab_glass_surface.dart';
import 'narrow_tab_icons.dart';
import 'narrow_tab_lens.dart';
import 'narrow_tabs.dart';

/// 底部虚化带的模糊量：比胶囊重一档。
///
/// 胶囊要透出底下内容的「形状 + 一点颜色」，14 就够；虚化带的目标不同——
/// 它要让滚到导航下方的卡片只剩轮廓、读不出字。共用 14 时 12.5 的字仍隐约
/// 可辨，22 之后基本融成色块，且不会反过来影响胶囊的玻璃质感。
final ImageFilter _fadeBlur = ImageFilter.blur(sigmaX: 22, sigmaY: 22);

/// 胶囊内容区的水平内边距。
///
/// 参考 App 截图实测：选中底左沿到胶囊**外沿** 9px @3x = 3pt，
/// 由「内容内边距 1 + 项间缝 2」凑成（胶囊没有描边，边缘靠阴影表达，
/// 详见 `NarrowTabBar.build`）。
const double kBottomNavContentInset = 1;

/// 每一项左右留的缝：不留给缝，相邻两项的选中底会连成一片。
const double kBottomNavItemGap = 2;

/// 选中底外缘到胶囊外沿的距离（= 参考实测的 3pt）。
///
/// 垂直方向同样成立：胶囊内高 61，选中底 55，上下各留 3。
const double kBottomNavItemInset =
    kBottomNavContentInset + kBottomNavItemGap;

/// 选中底的高度：胶囊内高减去上下各 [kBottomNavItemInset]。
///
/// 固定 55（61 − 6）而不是随内容撑开：选中底的宽高比是参考 App 的固定
/// 规格（65.7 × 54.7 实测），只能由容器给，靠图标 + 文字的自然高度会漂。
const double kBottomNavItemHeight =
    kBottomNavHeight - 2 * kBottomNavItemInset;

/// 选中底的圆角。
///
/// 与胶囊**同心**：外层胶囊高 61，`AppRadius.pill` 在绘制时被 clamp 成半高，
/// 即有效半径 30.5；内层再往里让 [kBottomNavItemInset]，圆角就跟着变成 27.5
/// —— 正好等于选中底半高（55/2），所以选中底本身也是胶囊形。
/// 内外两段弧线因此平行——写死一个小圆角（曾经的 14）会在选中项贴到
/// 胶囊最左/最右时露出"外圆内方"的折角。
///
/// 61 是奇数，半径只能落在半像素上；3x 屏是 82.5 设备像素，由系统抗锯齿
/// 渲染，看不到毛边。想回到整数就得把胶囊降回 60，那正是本次要修的差异。
const double kBottomNavItemRadius =
    kBottomNavHeight / 2 - kBottomNavItemInset;

/// 选中底里「图标 → 文案」的间距（画布间距，不是视觉空隙）。
///
/// 图标画布 24、描边图形只占中间约 17.9，上下各留约 3.05 的空白；再加这里的
/// 2 与文字行高留白，视觉空隙约 6.9pt，对齐参考 App 实测的 6.3pt。
/// 占位 6 会让视觉空隙到 10.9pt——两行明显散开，正是上一版的问题。
const double kBottomNavItemContentGap = 2;


/// 底部虚化带的高度：与列表留白同一口径。
///
/// 页面最后一行停在 `kBottomNavListInset` 之上，那时它正好落在虚化带顶端
/// 之外，不会被糊到；再高就会把能读的内容一起虚掉。
const double kBottomNavFadeHeight = kBottomNavListInset;

/// 虚化带的 Key（测试用来确认"这一层在、且不拦点击"）。
const Key kBottomNavFadeKey = Key('narrow-bottom-fade');

/// 窄屏底部导航：一条悬浮胶囊。
///
/// 形态按参考 App（千问）实测：左右各 20、距底 22、高 61、全圆角、
/// 半透明底 + 背景模糊 + 轻投影（无描边，边界靠阴影与略暗底色表达）。底部不叠加安全区
/// （见 [NarrowTabBarState.build] 的注释）。内容从它下面滚过——所以它不是
/// `Scaffold.bottomNavigationBar`（那是一整条实心槽位，压不出"浮着"的感觉），
/// 而是由 [NarrowTabs] 定位在内容层的上方。
///
/// 玻璃质感分三层叠出来，各自独立可调：
/// 1. 本体：`BackdropFilter` 模糊 + 半透明 `scheme.surface`；
/// 2. 边缘：[NarrowTabGlassEdge] 画的镜面高光与色散（走 `CustomPaint`，
///    因为 `BoxDecoration.border` 只能单色、而且这里刻意不画描边）；
/// 3. 动效：选中底在项间流动、按下收缩、选中回弹。
///
/// 没有做真折射（背景被边缘"吸入"的 lensing）——那需要片元着色器，
/// 属于下一步的事；这里的"液"来自更透的底 + 流动 + 回弹。
class NarrowTabBar extends StatefulWidget {
  const NarrowTabBar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final NarrowTab current;
  final ValueChanged<NarrowTab> onSelect;

  @override
  State<NarrowTabBar> createState() => NarrowTabBarState();
}

class NarrowTabBarState extends State<NarrowTabBar>
    with SingleTickerProviderStateMixin {
  /// 选中瞬间的回弹：先放大再收敛。
  ///
  /// 用显式控制器而不是隐式动画：隐式动画表达不了"过冲再回落"，
  /// 而且这里要统一受系统「减弱动态效果」控制。
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  late final Animation<double> _bounceScale = TweenSequence<double>(
    <TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1,
          end: 1.035,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 35,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1.035,
          end: 0.995,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 35,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.995,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
    ],
  ).animate(_bounce);

  /// 按住时的轻微收缩；松手或手势被取消即复原，不留残余。
  bool _pressed = false;

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  void _releasePress() {
    if (!_pressed) return;
    setState(() => _pressed = false);
  }

  void _select(NarrowTab tab, {required bool reduceMotion}) {
    // 点当前项不再弹一次：那会把"点了没反应"变成"点了抖一下"。
    if (tab != widget.current && !reduceMotion) {
      _bounce.forward(from: 0);
    }
    widget.onSelect(tab);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Padding(
      // 左右 20、距底 22（参考 App 截图实测，底部比左右多 2pt 是它的口径）。
      // 底部**不叠加安全区**：Home 指示条在距底 8~13pt，胶囊下沿在 22pt，
      // 两者本来就不重叠；再加一次 safeBottom 会把胶囊顶高约 34pt，出现
      // "底部比左右宽一大截"的观感（虚化带仍由 `NarrowTabFade` 自己带安全区）。
      padding: const EdgeInsets.fromLTRB(
        kBottomNavSideInset,
        0,
        kBottomNavSideInset,
        kBottomNavBottomGap,
      ),
      // `Listener` 而不是 `GestureDetector`：前者不进手势竞技场，
      // 不会抢走每个标签 `InkWell` 的水波纹与点击。
      child: Listener(
        onPointerDown: reduceMotion
            ? null
            : (_) => setState(() => _pressed = true),
        onPointerUp: (_) => _releasePress(),
        onPointerCancel: (_) => _releasePress(),
        child: AnimatedScale(
          scale: _pressed && !reduceMotion ? 0.97 : 1,
          duration: _pressed
              ? const Duration(milliseconds: 90)
              : const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: AnimatedBuilder(
            animation: _bounceScale,
            builder: (context, child) => Transform.scale(
              scale: reduceMotion ? 1 : _bounceScale.value,
              child: child,
            ),
            // 缩放只影响合成层：玻璃与阴影包在 `RepaintBoundary` 里，
            // 回弹期间不重绘它们。
            child: RepaintBoundary(child: _capsule(context)),
          ),
        ),
      ),
    );
  }

  Widget _capsule(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.pill);
    final dark = scheme.brightness == Brightness.dark;

    // 开关打开时背板交给 shader（真折射），染色也由玻璃自己给，
    // 这里只留极淡的一层保证 10.5sp 小字的对比度。
    final glass = liquidGlassBackplate(
      context: context,
      child: _capsuleBody(
        context,
        fillAlpha: dark ? 0.12 : 0.08,
        withEdge: false,
      ),
    );

    return DecoratedBox(
      // 投影画在裁剪之外：放进圆角裁剪里会被一并切掉。
      //
      // 只留一层轻投影，对齐参考 App 的实测：胶囊下方最暗处比背景暗 6.7%
      // （0.08 经模糊衰减后约 6.8%），扩散约 21pt、向下偏 4pt。原先那层
      // `0.05 / blur 2` 的贴边细节去掉——参考的胶囊边缘没有更深的细线，
      // 叠在无描边之上会变成一条可疑的暗边。
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child:
          glass ??
          ClipRRect(
            borderRadius: radius,
            // 高度先定死再交给 `LayoutBuilder`：透镜滤镜要按胶囊尺寸算缩放中心，
            // 而外面的约束高度是松的（Positioned 只给了 left/right/bottom）。
            child: SizedBox(
              height: kBottomNavHeight,
              child: LayoutBuilder(
                builder: (context, constraints) => BackdropFilter(
                  // 霜化 + 绕中心放大的透镜：背景在胶囊里变大、与胶囊外的同一块
                  // 内容错位，才有"隔着水滴看"的观感（见 `narrow_tab_lens.dart`）。
                  filter: NarrowTabLens.filterFor(constraints.biggest),
                  child: _capsuleBody(
                    context,
                    // 透到能让底下内容"看起来像隔着水"：0.82 会把透镜放大盖掉，
                    // 只剩一层均匀的膜。0.55 / 0.60 之后，放大出来的色带与轮廓
                    // 才看得见；再低导航上的 10.5sp 小字就压不住了。
                    fillAlpha: dark ? 0.60 : 0.55,
                    withEdge: true,
                  ),
                ),
              ),
            ),
          ),
    );
  }

  /// 胶囊内容与底座。
  ///
  /// [withEdge] 只在旧路径为真：液态玻璃的那道边缘由 shader 画（镜面高光、
  /// 色散、倒角都在里面），再叠一层自绘高光会重复。
  Widget _capsuleBody(
    BuildContext context, {
    required double fillAlpha,
    required bool withEdge,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.pill);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Stack(
      children: <Widget>[
        Container(
          key: kBottomNavKey,
          height: kBottomNavHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: kBottomNavContentInset,
          ),
          decoration: BoxDecoration(
            // **不画描边**：参考 App 的胶囊边缘是 254→246 的直接过渡，
            // 没有深色线圈。边界由略暗的底色 + 轻投影表达。
            color: scheme.surface.withValues(alpha: fillAlpha),
            borderRadius: radius,
          ),
          child: _content(context, reduceMotion: reduceMotion),
        ),
        if (withEdge)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                key: kBottomNavGlassKey,
                painter: NarrowTabGlassEdge(
                  // 胶囊高 61 → 有效圆角 30.5（`AppRadius.pill` 绘制时被 clamp）。
                  radius: kBottomNavHeight / 2,
                  highlight: AppColors.onAccent.withValues(alpha: 0.55),
                  warmEdge: AppPalette.of(
                    context,
                  ).accent.projectStart.withValues(alpha: 0.10),
                  coolEdge: scheme.primary.withValues(alpha: 0.08),
                  // 倒角的两面：顶上被压暗、底下被顶亮，玻璃才有厚度。
                  topShade: scheme.shadow.withValues(alpha: 0.20),
                  bottomGlow: AppColors.onAccent.withValues(alpha: 0.12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 胶囊内容区：一块流动的选中底 + 五个点击区。
  ///
  /// 结构必须是「底在下、项在上」的 `Stack`：选中底只有一块，切换时靠
  /// `AnimatedPositioned` 平移过去；如果还让每项各画一块，位移就退化成
  /// 两个淡入淡出叠在一起。
  Widget _content(BuildContext context, {required bool reduceMotion}) {
    final palette = AppPalette.of(context);
    const duration = Duration(milliseconds: 240);

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / NarrowTab.values.length;

        return Stack(
          children: <Widget>[
            AnimatedPositioned(
              duration: reduceMotion ? Duration.zero : duration,
              curve: Curves.easeOutCubic,
              left: widget.current.index * itemWidth + kBottomNavItemGap,
              top: kBottomNavItemInset,
              width: itemWidth - 2 * kBottomNavItemGap,
              height: kBottomNavItemHeight,
              child: DecoratedBox(
                // 这个 Key 挂在**可见的选中底**上，且同一时刻只有一块：
                // 尺寸回归测试靠它量高 55、内缩 3、宽 = 项宽 − 4。
                key: narrowTabBgKey(widget.current),
                decoration: BoxDecoration(
                  color: palette.accent.projectTint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(kBottomNavItemRadius),
                ),
              ),
            ),
            Positioned.fill(
              child: Row(
                children: <Widget>[
                  for (final tab in NarrowTab.values)
                    Expanded(
                      child: _NarrowTabItem(
                        tab: tab,
                        selected: tab == widget.current,
                        onTap: () => _select(tab, reduceMotion: reduceMotion),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 胶囊里的一项：图标在上、文案在下。
///
/// 选中底不在这里画——它已上移到 `NarrowTabBarState._content` 的 `Stack` 里，
/// 只有一块、在项间流动。这里只负责点击区、图标与文字。
class _NarrowTabItem extends StatelessWidget {
  const _NarrowTabItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final NarrowTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // 原型选中文字用的是 #A85E14——那不在 AppPalette 里。按规范不新增色值，
    // 改成「图标取项目强调色、文字取正文色 + 半粗」：10.5sp 的小字靠颜色压深
    // 在深色主题下会糊，靠字重与图标着色同样分得出选中。
    final accent = palette.accent;
    final color = selected ? accent.projectStart : palette.text.secondary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kBottomNavItemGap),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          type: MaterialType.transparency,
          // 水波纹与选中底必须是同一个圆角，否则波纹会画出底色之外。
          child: InkWell(
            key: narrowTabKey(tab),
            borderRadius: BorderRadius.circular(kBottomNavItemRadius),
            onTap: onTap,
            // 高 55（胶囊 61 减去上下各 3）仍要显式给：命中区跟着选中底走，
            // 不能靠图标 + 文字的自然高度（约 40）撑出来。
            child: SizedBox(
              height: kBottomNavItemHeight,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  NarrowTabIcon(
                    glyph: narrowGlyphOf(tab),
                    color: color,
                    selected: selected,
                  ),
                  const SizedBox(height: kBottomNavItemContentGap),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    style:
                        (Theme.of(context).textTheme.labelSmall ??
                                const TextStyle())
                            .copyWith(
                              fontSize: AppFontSize.xs,
                              height: AppLineHeight.tight,
                              letterSpacing: AppLetterSpacing.tight,
                              fontWeight: selected
                                  ? AppWeight.semiBold
                                  : AppWeight.medium,
                              color: selected
                                  ? palette.text.primary
                                  : palette.text.secondary,
                            ),
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部整条渐隐虚化带：从胶囊上沿再往上一点，一路铺到屏幕底（含左右两侧）。
///
/// 胶囊是浮在内容之上的，列表原本会从它两侧与下方露出来并被硬边切断。
/// 这里自下而上铺一条虚化带（画法与顶部那条共用 [EdgeFade]）：
/// 贴底全糊、往上渐清，颜色由 `scheme.surface` 带出，深浅主题与主题包自动跟随。
///
/// 只做视觉：[IgnorePointer] 包住，胶囊两侧与下方的点击照旧落到列表上。
class NarrowTabFade extends StatelessWidget {
  const NarrowTabFade({super.key});

  /// 底端实心段的底色强度。
  ///
  /// 偏浓：底下卡片只留轮廓与色块。但不给满值——留两成通透才能看出「下面
  /// 有东西」，也与胶囊 92% 的底拉开一层，不会糊成一整块实心色。
  static const double _fillAlpha = 0.8;

  /// 过渡起点（占整条带高度的比例，自底向上量）。
  ///
  /// 胶囊上沿在 76/96 ≈ 0.79 处，实心段走到 0.62：浓的那段略往上延，
  /// 衰减更靠上更缓，胶囊上沿附近仍留一段淡过渡，不压出看得见的色阶。
  static const double _fillStop = 0.62;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        key: kBottomNavFadeKey,
        // 安全区一起糊掉：iPhone 的横条那一段也是"底"。
        height: kBottomNavFadeHeight + MediaQuery.paddingOf(context).bottom,
        child: EdgeFade(
          direction: EdgeDirection.bottom,
          blur: _fadeBlur,
          fillAlpha: _fillAlpha,
          fillStop: _fillStop,
        ),
      ),
    );
  }
}
