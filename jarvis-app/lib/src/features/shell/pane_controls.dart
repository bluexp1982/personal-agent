import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/models.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_icon_button.dart';
import '../../core/window_chrome.dart';
import '../../core/project_providers.dart';
import 'file_pane_state.dart';
import 'nav_chevron_icon.dart';
import 'new_conversation_action.dart';
import 'new_conversation_icon.dart';
import 'panel_page.dart';
import 'rail_section_icons.dart';
import 'shell_layout_state.dart';
import 'sidebar_toggle_icon.dart';
import 'window_fullscreen.dart';

/// 栏头里图标按钮的统一尺寸：24 的命中区放进 [kPaneHeaderHeight] 高的首行，
/// 既够点也不高过右栏标签（同一条 Row 里以标签高度为准）。
///
/// 形状走 [shellIconButtonStyle]：悬停底是 8dp 圆角方形，与同一行里的标签
/// 圆角同值；Material 默认的正圆在这一排小方块里显得格格不入。
ButtonStyle _headerButtonStyle() =>
    shellIconButtonStyle(minimumSize: const Size.square(kPaneHeaderButtonSize));

/// 栏头左起线：首行第一枚控件（开合按钮）左缘到**窗口**左缘的距离。
///
/// 只有两种取值，取决于这一行左端是不是系统红绿灯：
/// - 是：让开 [kMacWindowButtonsWidth]，按钮落在红绿灯右侧；
/// - 否（系统全屏把红绿灯收走、非 macOS 平台）：回到内容线 [kPaneContentInset]。
///
/// 左栏栏头与中栏栏头都从这里取值，不再各写一份数字：两边一旦分叉，
/// 左栏展开 / 收起时同一枚开合按钮就会横向跳几 dp（历史上正是被中栏栏头
/// 外层的 4dp 内边距顶出去的）。
double paneHeaderLeadingLine({required bool reserveForTrafficLights}) =>
    reserveForTrafficLights ? kMacWindowButtonsWidth : kPaneContentInset;

/// 左栏开合按钮。
///
/// 同一时刻只渲染一个：左栏展开时在左栏栏头，收起后由
/// [onlyWhenCollapsed] 让中栏栏头接管。`kRailToggleKey` 因此不会重复。
class RailToggleButton extends ConsumerWidget {
  const RailToggleButton({
    super.key,
    this.onlyWhenCollapsed = false,
    this.color,
    this.size = kPaneHeaderIconSize,
  });

  /// 只在左栏收起时出现。中栏栏头用它换到展开入口。
  final bool onlyWhenCollapsed;

  /// 深色头图/终端状态栏里需要显式给白色，默认跟随 `IconTheme`。
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(railCollapsedProvider);
    if (onlyWhenCollapsed && !collapsed) {
      return const SizedBox.shrink();
    }

    return IconButton(
      key: kRailToggleKey,
      tooltip: collapsed ? '显示侧栏' : '隐藏侧栏',
      onPressed: () => ref.read(railCollapsedProvider.notifier).toggle(),
      style: _headerButtonStyle(),
      iconSize: size,
      icon: SidebarToggleIcon(size: size, color: color),
    );
  }
}

/// 后退 / 前进：在中栏打开过的页面之间前后切换。
///
/// 位置始终跟着开合按钮走：宽屏左栏展开时排在它后面，左栏收起后由
/// [onlyWhenCollapsed] 让中栏栏头接管。两处若同时渲染，[kRailBackKey] 与
/// [kRailForwardKey] 就会在同一棵树里重复，测试会直接抛异常。
///
/// 两处读的是同一份可用性（`shellNavHistoryProvider`），不会出现"栏头能点、
/// 中栏栏头却灰着"的分裂；真正改页面的仍是 `shellTargetProvider` 那一个状态。
///
/// 两枚按钮之间不留额外间距：命中区本来就是 24，图标只有 14，
/// 紧贴时图标之间已有 10dp，和左栏行的图标节奏一致。
class HistoryNavButtons extends ConsumerWidget {
  const HistoryNavButtons({super.key, this.onlyWhenCollapsed = false});

  /// 只在左栏收起时出现。中栏栏头用这个口径与左栏那一份互斥。
  final bool onlyWhenCollapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(railCollapsedProvider);
    if (onlyWhenCollapsed && !collapsed) {
      return const SizedBox.shrink();
    }

    final history = ref.watch(shellNavHistoryProvider);

    // notifier 在按下时才取：provider 万一被重建，build 期间抓下来的那个
    // 实例已经 dispose，点下去会抛"用了已销毁的 notifier"。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _HistoryNavButton(
          buttonKey: kRailBackKey,
          forward: false,
          enabled: history.canGoBack,
          onPressed: () => ref.read(shellTargetProvider.notifier).goBack(),
        ),
        _HistoryNavButton(
          buttonKey: kRailForwardKey,
          forward: true,
          enabled: history.canGoForward,
          onPressed: () => ref.read(shellTargetProvider.notifier).goForward(),
        ),
      ],
    );
  }
}

/// 栏头里的后退 / 前进：有可去的页面才亮，没有就置灰且点不动。
///
/// 不可用给 `onPressed: null`，由 `IconButton` 自己吞掉点击、不弹提示条：
/// 「即将支持」那类提示条的语义是"这个动作坏了"，而这里只是"还没有上一页"。
/// 箭头显式染成 `text.disabled`，与左栏禁用行同一个口径——自绘折线读的是
/// `IconTheme`，禁用色在这一层给死，不依赖 `IconButton` 内部怎么合主题。
class _HistoryNavButton extends StatelessWidget {
  const _HistoryNavButton({
    required this.buttonKey,
    required this.forward,
    required this.enabled,
    required this.onPressed,
  });

  final Key buttonKey;
  final bool forward;
  final bool enabled;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: buttonKey,
      tooltip: forward ? '前进' : '后退',
      onPressed: enabled ? onPressed : null,
      style: _headerButtonStyle(),
      iconSize: kPaneHeaderIconSize,
      icon: NavChevronIcon(
        forward: forward,
        size: kPaneHeaderIconSize,
        color: enabled ? null : AppPalette.of(context).text.disabled,
      ),
    );
  }
}

/// 中栏栏头里的「新建会话」。
///
/// 只在左栏收起时出现：展开时那颗整行宽的按钮就在侧栏顶部，栏头再放一枚
/// 等于把同一个动作摆两遍；收起后侧栏连同它的入口一起消失，不给这颗按钮
/// 就只剩"先把侧栏展开"一条路。
///
/// 落点与侧栏那颗完全一致（[hostProjectFor]）：当前选中项所属项目，
/// 没有选中项就用当前模式的第一个。一个项目都没有时建无归属直聊——
/// 会话不必挂在目录上，按钮因此不会再置灰。
class NewConversationButton extends ConsumerWidget {
  const NewConversationButton({super.key, this.size = kPaneHeaderIconSize});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(railCollapsedProvider);
    if (!collapsed) {
      return const SizedBox.shrink();
    }

    // 列表还在加载时按空处理：按钮先灰着，数据回来自己就亮。
    final projects = ref.watch(projectsProvider);
    final host = hostProjectFor(
      projects.asData?.value ?? const <Project>[],
      ref.watch(shellTargetProvider),
    );

    // 与开合按钮之间留 2dp：两枚按钮的命中区都是 24，紧贴时图标之间
    // 只有 10dp，看着像一组连体图标（终端状态栏那对同款也用 2）。
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: IconButton(
        key: kNewConversationKey,
        tooltip: host == null
            ? '新开一条无项目的对话'
            : '在「${host.name}」里新开一个会话',
        onPressed: () => createConversation(context, ref, host: host),
        style: _headerButtonStyle(),
        iconSize: size,
        icon: NewConversationIcon(size: size),
      ),
    );
  }
}

/// 中栏右上角的右栏开关。
///
/// 只在右栏收起时出现：面板打开后，隐藏入口收在面板自己的工具条里
/// （见 `project_panel.dart`）。同一屏永远只有一个"开 / 关面板"的按钮，
/// 不会出现"点了上面那个却关掉下面那个"的疑义。
class FilePaneToggleButton extends ConsumerWidget {
  const FilePaneToggleButton({
    super.key,
    this.color,
    this.size = kPaneHeaderIconSize,
  });

  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(filePaneVisibleProvider);
    if (visible) {
      return const SizedBox.shrink();
    }

    return IconButton(
      key: kFilePaneToggleKey,
      tooltip: '显示右侧栏',
      onPressed: () => ref.read(filePaneVisibleProvider.notifier).show(),
      style: _headerButtonStyle(),
      iconSize: size,
      icon: SidebarToggleIcon(mirrored: true, size: size, color: color),
    );
  }
}

/// 窄屏顶栏的「面板」入口。
///
/// 宽屏靠中栏栏头那个开合按钮进面板；窄屏既没有中栏栏头也没有第三栏，
/// 于是在顶栏放一个入口，把面板以整页形式推上来（见 `panel_page.dart`）。
/// 终端搬进面板后，这是窄屏唯一能用到 SSH 的路径，不能省。
class PanelEntryButton extends ConsumerWidget {
  const PanelEntryButton({
    super.key,
    this.size = kPaneHeaderIconSize,
    this.mobile = false,
    this.bare = false,
  });

  final double size;

  /// 手机版页头：换成 38dp 玻璃圆钮（见 `core/ui/mobile_top_bar.dart`）。
  ///
  /// 只在窄屏页头里为真；宽屏栏头仍走 24/14 的方钮规格。
  final bool mobile;

  /// 作为 `MobileTopBarButtonGroup` 里的一格参与排布：不再自带玻璃底。
  ///
  /// 只在 [mobile] 为真时有意义；宽屏的 `IconButton` 形态本来就是整栏共用
  /// 底色，没有"自己一层玻璃"这回事。
  final bool bare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (mobile) {
      return MobileTopBarButton(
        key: kPanelEntryKey,
        bare: bare,
        icon: Icons.view_sidebar_outlined,
        tooltip: '打开面板',
        onPressed: () => openPanelPage(context),
      );
    }

    return IconButton(
      key: kPanelEntryKey,
      tooltip: '打开面板',
      onPressed: () => openPanelPage(context),
      style: _headerButtonStyle(),
      iconSize: size,
      icon: const Icon(Icons.view_sidebar_outlined),
    );
  }
}

/// 左栏「项目」标题行里的小图标按钮：搜索 / 视图选项 / 新建项目。
///
/// 与栏头的 [IconButton] 不是一族：这一簇贴着分组标题，命中区 24、图标 16、
/// 悬停只浮出一块 [kShellIconButtonRadius] 圆角的淡灰。间距由调用方给（彼此 2dp），
/// 内部不再加 `IconButton` 那圈默认内边距，否则三个图标会散开成一排散点。
///
/// 不用 `IconButton`/`InkWell`：这块底色要当帧切换，而水波纹得先找 `Material`
/// 祖先，侧栏里那层在很远处，涟漪会画到不该画的地方。
class RailSectionIconButton extends StatefulWidget {
  const RailSectionIconButton({
    super.key,
    this.icon,
    this.iconBuilder,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
    this.iconSize = kRailItemIconSize,
  }) : assert(icon != null || iconBuilder != null, '图标二选一：icon 或 iconBuilder');

  /// 图标字体里的字形。自绘图标（见 [RailSectionGlyph]）改用 [iconBuilder]。
  final IconData? icon;

  /// 自绘图标：把当前该用的颜色交给调用方，避免这一层去猜每枚图标的高亮规则。
  final Widget Function(Color color)? iconBuilder;

  final String tooltip;
  final VoidCallback onPressed;

  /// 浮层展开时保持高亮，回答"这块灰是点出来的"。
  final bool active;
  final double iconSize;

  @override
  State<RailSectionIconButton> createState() => _RailSectionIconButtonState();
}

class _RailSectionIconButtonState extends State<RailSectionIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlighted = widget.active || _hovering;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            width: kPaneHeaderButtonSize,
            height: kPaneHeaderButtonSize,
            decoration: BoxDecoration(
              // 透明态用同一个颜色的 0 透明度而不是 `Colors.transparent`：
              // 后者是透明黑，插值时会出现一段偏暗的灰。
              color: scheme.surfaceContainerHighest.withValues(
                alpha: highlighted ? 0.9 : 0,
              ),
              borderRadius: BorderRadius.circular(kShellIconButtonRadius),
            ),
            // `Center` 是必须的：容器把命中区定死了 24dp，直接当 child 会给出
            // 紧约束，`SizedBox.square(iconSize)` 的自绘图标就会被拉成 24 的方框，
            // 画出来比同尺寸的字体图标大一圈。
            child: Center(
              child: Builder(
                builder: (context) {
                  final color = widget.active
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant;
                  final custom = widget.iconBuilder;
                  if (custom != null) {
                    return custom(color);
                  }
                  return Icon(widget.icon, size: widget.iconSize, color: color);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「项目」标题行里的搜索入口。
///
/// 按参考图先占位：图标、悬停反馈与提示都做好，但不接任何检索逻辑。
/// 假实现的搜索比"暂时没有搜索"更让人困惑——点下去什么也搜不到，
/// 用户会以为索引坏了。
class RailSearchButton extends StatelessWidget {
  const RailSearchButton({super.key, this.size = kRailItemIconSize});

  final double size;

  @override
  Widget build(BuildContext context) {
    return RailSectionIconButton(
      key: kRailSearchKey,
      iconBuilder: (color) => RailSectionGlyph(
        kind: RailSectionGlyphKind.search,
        color: color,
        size: size,
      ),
      tooltip: '搜索（即将支持）',
      iconSize: size,
      onPressed: () => ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('搜索即将支持'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        ),
    );
  }
}

/// 左栏收起后，中栏贴到窗口左边：把首行左端的留白补到 [paneHeaderLeadingLine]。
///
/// 左栏展开时这段留白由左栏自己的栏头承担，这里返回零尺寸占位；收起后
/// 中栏栏头接管同一枚开合按钮，占位宽度要让它落在**与展开时同一条竖线**上：
///
/// 外层容器（`EmbeddedToolbar`）自己已经让出了 [leadingInset] 的左内边距，
/// 所以这里只补差值。两者相加恒等于 [paneHeaderLeadingLine]，与调用方
/// 记不记得配平无关。
///
/// 没有红绿灯的情况（系统全屏、非 macOS）同样要补到内容线：展开态那边
/// 落在 12，收起态若只剩外层那 4dp，按钮会整体左跳 8dp。
class MacTrafficLightInset extends ConsumerWidget {
  const MacTrafficLightInset({super.key, this.leadingInset = 0});

  /// 外层容器已经给出的左内边距，占位要扣掉它。
  final double leadingInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(railCollapsedProvider);
    if (!collapsed) {
      return const SizedBox.shrink();
    }
    final fullScreen = ref.watch(windowFullScreenProvider);
    final line = paneHeaderLeadingLine(
      reserveForTrafficLights: usesHiddenWindowTitleBar && !fullScreen,
    );
    // 不让它变成负数：外层内边距一旦大过左起线，负宽度会直接抛约束异常。
    return SizedBox(width: math.max(0, line - leadingInset));
  }
}
