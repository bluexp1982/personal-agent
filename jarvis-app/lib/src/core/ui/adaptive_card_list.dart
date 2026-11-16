import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/app_palette.dart';
import '../design/app_text_styles.dart';
import '../design/app_tokens.dart';

/// 单张卡片的最小宽度：可用宽度放不下第二列时，就退回单列铺满整行。
const double kAdaptiveCardMinWidth = 320;

/// 自适应卡片列表：窄屏一列铺满，宽屏按可用宽度并排多列；每项自动套 [AdaptiveCard]。
///
/// 会话 / 任务 / 录音三处列表共用它：列数、间距、卡片底色与选中底都只在这里
/// 定义，以后调外观只改这一处。页面只负责卡片**内容**。
///
/// 用 [Wrap] 而不是 `GridView`：卡片高度由内容（文字行数、系统字体缩放）决定，
/// 写死 `mainAxisExtent` 会在大字号下裁掉内容；这些列表上限在 50~100 条，
/// 一次性构建的代价可以接受。
class AdaptiveCardList extends StatelessWidget {
  const AdaptiveCardList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.isSelected,
    this.padding = EdgeInsets.zero,
    this.minItemWidth = kAdaptiveCardMinWidth,
    this.spacing = 12,
    this.runSpacing,
    this.physics,
    this.scrollable = true,
  });

  final int itemCount;

  /// 只返回卡片内容：外壳（底色 / 圆角 / 选中底）由 [AdaptiveCard] 统一套。
  ///
  /// 点击留给内容自己的 `ListTile.onTap` / `InkWell`，避免壳与内容双层手势。
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// 管理态的选中底：为真时该卡片换成主色 8% 的混合底；为空表示全不选中。
  final bool Function(int index)? isSelected;

  final EdgeInsets padding;
  final double minItemWidth;

  /// 列间距。行间距默认与它相同，见 [runSpacing]。
  final double spacing;

  /// 行间距。为空时取 [spacing]。
  ///
  /// 录音行自带状态胶囊与两行预览，行与行之间只需要一条窄缝，列与列之间
  /// 却要有明显分界，所以两处分开放。
  final double? runSpacing;

  /// 交给外层 `RefreshIndicator` 的页面传 [AlwaysScrollableScrollPhysics]，
  /// 否则内容不满一屏时下拉手势不会落到滚动视图上。
  final ScrollPhysics? physics;

  /// 是否自带纵向滚动，默认 `true`。
  ///
  /// 嵌在**别的**滚动容器里时传 `false`：只返回网格本身，高度由内容决定，
  /// 不会和上层形成同向嵌套滚动（录音页按日期分组，每组一个列表）。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final usable = math.max(
          0.0,
          constraints.maxWidth - padding.horizontal,
        );
        // 列数按「每列都不小于 minItemWidth」取整：320 时 700dp 放两列。
        final columns = math.max(
          1,
          ((usable + spacing) / (minItemWidth + spacing)).floor(),
        );
        final itemWidth = (usable - spacing * (columns - 1)) / columns;

        final cards = Wrap(
          spacing: spacing,
          runSpacing: runSpacing ?? spacing,
          children: <Widget>[
            for (var index = 0; index < itemCount; index++)
              SizedBox(
                width: itemWidth,
                child: AdaptiveCard(
                  selected: isSelected?.call(index) ?? false,
                  child: itemBuilder(context, index),
                ),
              ),
          ],
        );

        if (!scrollable) {
          // 内边距仍按上面的宽度扣减过，这里只是把它补回去给父级看。
          return padding == EdgeInsets.zero
              ? cards
              : Padding(padding: padding, child: cards);
        }
        return SingleChildScrollView(
          padding: padding,
          physics: physics,
          child: cards,
        );
      },
    );
  }
}

/// 统一卡片外壳：`surfaceContainerLow` 浅底 + [AppRadius.md] 圆角，无描边。
///
/// 选中底是「主色 8%」与卡底的预乘结果，等价于过去 `Card` 底叠
/// `selectedTileColor`，颜色随主题走、不新增 token。
///
/// 不承载点击：内容自己的 `ListTile` / `InkWell` 负责手势与悬停；这里只做
/// [Clip.antiAlias] 裁剪，保证水波纹不溢出圆角。
class AdaptiveCard extends StatelessWidget {
  const AdaptiveCard({super.key, required this.child, this.selected = false});

  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.08),
              scheme.surfaceContainerLow,
            )
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 卡片内文：图标块 + 标题行（可带右侧徽标）+ 可选预览 + 元信息。
///
/// 录音 / 会话 / 任务三处共用同一套几何与字阶：34 图标块、12 内边距、
/// 标题 14 / w500、预览与元信息 11.5。差异只剩内容本身（有没有预览、
/// 右侧挂状态胶囊还是徽标）。
///
/// 点击与悬停由这里的 [InkWell] 负责，卡片壳 [AdaptiveCard] 只提供底色。
class AdaptiveCardRow extends StatelessWidget {
  const AdaptiveCardRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    this.trailing,
    this.preview,
    this.meta,
    this.onTap,
    this.selected = false,
    this.leading,
  });

  final IconData icon;
  final Color iconColor;
  final String title;

  /// 标题行右侧的徽标（状态胶囊 / 「待确认」）。**不画右箭头**：
  /// 整张卡片可点，箭头在三处只会各写一遍又各差一点。
  final Widget? trailing;

  /// 预览行，最多两行；当前只有录音卡有。
  final String? preview;

  /// 元信息（时间、大小、状态…）。
  final String? meta;

  final VoidCallback? onTap;

  /// 管理态选中：标题换成主色，等价于旧 `ListTile.selected` 的文字色。
  final bool selected;

  /// 覆盖左侧图标块（管理态复选框）；给了就替换掉图标块，
  /// 槽位固定 34，进出管理态内容不左右跳。
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 34,
              height: 34,
              child:
                  leading ??
                  AdaptiveCardIconTile(icon: icon, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.row.copyWith(
                            fontWeight: AppWeight.medium,
                            color: selected ? scheme.primary : null,
                          ),
                        ),
                      ),
                      if (trailing != null) ...<Widget>[
                        const SizedBox(width: 8),
                        trailing!,
                      ],
                    ],
                  ),
                  if (preview != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      preview!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.hint,
                    ),
                  ],
                  if (meta != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(meta!, style: text.meta),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片左侧的图标块：34×34、[AppRadius.sm]、主题色 12% 淡底、18dp 图标。
///
/// 12% 复用 [AppStatusColors.surfaceOf]：它和状态胶囊是同一档值，这里只是
/// 借这层淡底把图标托起来，不表示状态。
class AdaptiveCardIconTile extends StatelessWidget {
  const AdaptiveCardIconTile({
    super.key,
    required this.icon,
    required this.color,
  });

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.of(context).status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}
