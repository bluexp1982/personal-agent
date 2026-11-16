import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/agent_menu.dart';

/// 会话产物卡片的**唯一外壳**。
///
/// 生成文件、图片、视频三类产物长得一样：左边类型图标，右边标题与状态胶囊，
/// 下面是等宽主行（文件路径 / 保存时的建议名）与灰字详情行，最下面是动作区；
/// 图片与视频可以在顶部多一块缩略图。
///
/// 为什么拆成「壳 + 两个适配层」（`MediaArtifactCard` / `FileWriteArtifactCard`）：
/// 壳保证所有产物视觉一致，适配层吸收各自的差异（媒体要下载字节、文件要做
/// 覆盖决策）。下载逻辑塞进壳里会让文件卡无谓地变成有状态组件。
class ArtifactCard extends StatelessWidget {
  const ArtifactCard({
    super.key,
    required this.icon,
    required this.title,
    this.chip,
    this.primaryLine = '',
    this.detailLine = '',
    this.extraLines = const <String>[],
    this.thumbnail,
    this.actions = const <Widget>[],
    this.tone,
  });

  /// 类型图标（文件 / 图片 / 影片）。
  final IconData icon;

  /// 标题：`生成文件` / `生成的图片` / `生成的视频` / `要覆盖已有文件`。
  final String title;

  /// 状态胶囊（只有文件写入有状态）。为 null 时不占位。
  final Widget? chip;

  /// 等宽主行：项目内路径，或产物保存时的建议文件名。
  final String primaryLine;

  /// 灰字详情行：`项目内 · 14.2 KB` / `qwen-image-3.0 · 1328×1328 · 2.4 MB`。
  final String detailLine;

  /// 附加行：备份路径、过期提示、提示词。字号比详情行再小一档。
  final List<String> extraLines;

  /// 顶部缩略图：图片比例盒或视频占位块。
  final Widget? thumbnail;

  /// 动作区（右下角），按传入顺序排。通常用 [ArtifactActionButton] 与
  /// [ArtifactSaveMenu] 构造，保证三类卡片的按钮长得一样。
  final List<Widget> actions;

  /// 描边色：待确认覆盖时用警示色，其余用中性描边。
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = AppText.of(context);

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontSize: AppFontSize.base,
                  color: palette.text.primary,
                ),
              ),
            ),
            if (chip != null) ...<Widget>[const SizedBox(width: 8), chip!],
          ],
        ),
        if (primaryLine.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            primaryLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.mono(
              size: AppFontSize.sm,
              color: palette.text.primary,
              height: AppLineHeight.normal,
            ),
          ),
        ],
        if (detailLine.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            detailLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: AppFontSize.sm,
              color: palette.text.tertiary,
            ),
          ),
        ],
        for (final line in extraLines) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            line,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: AppFontSize.xs,
              color: palette.text.tertiary,
            ),
          ),
        ],
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: tone?.withValues(alpha: 0.55) ?? scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (thumbnail != null) ...<Widget>[
            // 缩略图水平居中：图片按自身比例算宽度，靠左排会在右侧留出一条
            // 与卡片内边距无关的空档，看起来像整张卡被裁掉了一半。
            Align(alignment: Alignment.center, child: thumbnail!),
            const SizedBox(height: 10),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 18, color: tone ?? palette.text.secondary),
              const SizedBox(width: 8),
              Expanded(child: heading),
            ],
          ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            // 窄屏上按钮会换行，`Wrap` 比 `Row` 更稳。
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: 8, runSpacing: 8, children: actions),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「打开」的唯一图标。
///
/// 三类产物（文件 / 图片 / 视频）都用这一枚：以前图片用全屏箭头、视频用播放三角、
/// 文件用外链箭头，同一列卡片里三种"打开"看起来像三种不同的动作。
/// 图标语义是"打开这个文件"，与产物的媒体类型无关。
const IconData kArtifactOpenIcon = Icons.open_in_new;

/// 产物卡片的动作按钮：主操作（打开）用 tonal 填充，次操作（保存）用文字按钮。
///
/// 三类产物共用这一份，避免"图片卡的打开是填充钮、文件卡的文字钮"这种
/// 同一屏里两套按钮语言。
class ArtifactActionButton extends StatelessWidget {
  const ArtifactActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 请求进行中：图标换成进度圈并置灰。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final leading = busy
        ? const SizedBox(
            width: kArtifactActionIconSize,
            height: kArtifactActionIconSize,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: kArtifactActionIconSize);

    // 卡片上的动作不分主次：字体颜色、字号、悬停底与尺寸都由 `TextButton.icon`
    // 的主题默认值给出，「保存」与「打开」看起来是同一档按钮。
    // 以前「打开」用 tonal 填充，同一行里像两个层级的操作，用户会以为只能点一个。
    return TextButton.icon(
      onPressed: busy ? null : onPressed,
      icon: leading,
      label: Text(label),
    );
  }
}

/// 卡片动作按钮的图标尺寸。
///
/// 独立成常量是因为保存菜单的触发器（`ArtifactSaveMenu`）不走 [ArtifactActionButton]，
/// 但两枚按钮必须一模一样高——18 写在两处迟早会漂。
const double kArtifactActionIconSize = 18;

/// 「保存」下拉：媒体有「项目 / 本地」两个落点，文件只有一个落点。
///
/// 走全站唯一的菜单组件 [AgentMenu]（`MenuAnchor` + `MenuItemButton`）而不是
/// Material 的 `PopupMenuButton`：后者是系统默认的淡色矩形高亮，和输入栏、
/// 标签栏、左栏那些菜单不是一套观感。卡片是最常点开菜单的地方，更不该例外。
///
/// 触发器保留原来的「保存」+ `save_alt` 外观；按右边缘对齐展开，
/// 因为它在卡片右下角，向左长才不会顶出视口。
class ArtifactSaveMenu<T> extends StatelessWidget {
  const ArtifactSaveMenu({
    super.key,
    required this.items,
    required this.onSelected,
    this.enabled = true,
    this.label = '保存',
  });

  final List<AgentMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    return AgentMenu<T>(
      width: AgentMenuStyle.panelMinWidth,
      alignment: AlignmentDirectional.bottomEnd,
      alignmentOffset: AgentMenuStyle.rightAlignedOffset(
        AgentMenuStyle.panelMinWidth,
      ),
      // 触发器自带点击（TextButton 自己有 onPressed），组件只负责开合状态与浮层。
      triggerHandlesTap: false,
      groups: <AgentMenuGroup<T>>[
        AgentMenuGroup<T>(items: items),
      ],
      onSelected: onSelected,
      // 与同一行的「打开」按钮（`ArtifactActionButton`）同一套写法：尺寸、内边距、
      // 禁用态颜色都由 TextButton 自己给，不在这里另铺一层面板。
      builder: (context, controller, open, hovering) => TextButton.icon(
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
        icon: const Icon(
          Icons.save_alt,
          size: kArtifactActionIconSize,
        ),
        label: Text(label),
      ),
    );
  }
}

/// 状态胶囊：与录制列表、文件卡同一套配色，不另造一种视觉。
class ArtifactStatusChip extends StatelessWidget {
  const ArtifactStatusChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(color),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: palette.status.borderOf(color)),
      ),
      child: Text(
        label,
        style: AppText.of(context).badge.copyWith(color: color),
      ),
    );
  }
}
