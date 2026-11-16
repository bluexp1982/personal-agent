import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/account.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_surface.dart';
import '../../core/design/app_tokens.dart';
import '../../core/memory/memory_providers.dart';
import '../../core/session.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_insets.dart';
import '../../core/ui/top_bar_fade.dart';
import '../../core/window_chrome.dart';
import '../canvas/canvas_navigation.dart';
import '../memory/memory_navigation.dart';
import '../recordings/recording_mini_bar.dart';
import '../projects/create_project_dialog.dart';
import '../settings/settings_dialog.dart';
import 'chat_window_layer.dart';
import 'chat_window_state.dart';
import 'file_pane_state.dart';
import 'narrow_tabs.dart';
import 'panel_fullscreen.dart';
import 'pane_controls.dart';
import 'pane_surface.dart';
import 'rail_navigator.dart';
import 'shell_dividers.dart';
import 'shell_geometry.dart';
import 'shell_layout_state.dart';
import 'shell_pane.dart';
import 'shell_resize_handle.dart';
import 'immersive_fullscreen.dart';
import 'immersive_fullscreen_hint.dart';
import 'window_fullscreen.dart';
import 'project_panel.dart';

// 侧栏宽度等布局常量跟着导航状态一起放在 `shell_layout_state.dart`；
// 这里重新导出，调用方（含测试）仍可以只 import `home_shell.dart`。
export 'shell_layout_state.dart' show kShellBreakpoint, kShellRailWidth;

/// 主界面骨架：项目 → 会话/任务。
///
/// 项目只有一份列表，界面不再区分 CODE / WORK：需要 Git 能力的项目在创建时
/// 勾选「Git 仓库」，其余一律按普通项目处理，背景与强调色由主题决定（内置为蓝）。
///
/// 终端不在这里：它是右侧面板里的一个标签（见 `ProjectPanel`）。
/// 好处是窄屏不再为了终端整页换掉项目列表，宽屏也能一边看会话一边敲命令。
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.session});

  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 面板全屏 = "面板吃掉中栏"。左侧栏不参与：全屏看终端时还得能切项目，
    // 左栏藏起来反而让人找不到回去的路。所以只要"按过全屏 + 面板还开着"。
    final wantsFullscreen =
        ref.watch(panelFullscreenProvider) &&
        ref.watch(filePaneVisibleProvider);

    // 沉浸式全屏：与上面那套并列的另一种全屏，语义完全不同——
    // 它要把左栏、分隔线、对侧那一栏都藏掉，只留当前这一块内容，
    // 并且会请窗口进入原生全屏。终端、图片 / PDF 预览与无限画布共用这一套，
    // 差别只在于"谁按的按钮"（见 `ImmersiveSurface`）：右栏标签占满窗口，
    // 中栏画布则占满窗口。
    final immersiveSurface = ref.watch(immersiveFullscreenProvider);
    final paneVisible = ref.watch(filePaneVisibleProvider);
    final activeTab = ref.watch(filePaneTabProvider.select((s) => s.active));
    final canvasSelected = ref.watch(
      shellTargetProvider.select((target) => target is CanvasTarget),
    );
    final immersiveFullscreen = ref.read(immersiveFullscreenProvider.notifier);

    /// 哪些标签允许独占整窗：终端与所有文件预览（文本 / 代码 / Markdown /
    /// 图片 / PDF / 视频）。
    ///
    /// 空白页与浏览器没有"全屏"入口，不该被这一套藏起来。
    bool canImmersive(FilePaneTab? tab) =>
        tab == FilePaneTab.terminal || tab == FilePaneTab.preview;

    /// 当前全屏是不是这一种宿主。回调里现读而不闭包捕获：两个状态在同一帧
    /// 一起变时，闭包里那份可能是上一次 build 的值。
    bool immersiveIs(ImmersiveSurface surface) =>
        ref.read(immersiveFullscreenProvider) == surface;

    // 面板被收起、或者标签被切走：沉浸模式的两个出口（标签栏、关闭按钮）都跟着
    // 消失了，再留在里面就是一间没有门的房间。
    //
    // 只对"右栏占着全屏"那一种生效：画布改的是中栏，跟右栏标签无关，
    // 右栏在画布全屏期间本来就不渲染，不该被它的标签变化踢出全屏。
    ref.listen<bool>(filePaneVisibleProvider, (previous, visible) {
      if (!visible && immersiveIs(ImmersiveSurface.panel)) {
        immersiveFullscreen.exit();
      }
    });
    ref.listen<FilePaneTab?>(filePaneTabProvider.select((s) => s.active), (
      previous,
      active,
    ) {
      if (!canImmersive(active) && immersiveIs(ImmersiveSurface.panel)) {
        immersiveFullscreen.exit();
      }
    });
    // 中栏切走画布（左栏点了别的页、聊天被叫回来…）：画布已经不在了，
    // 再留在全屏里就是一间没有门的房间。
    ref.listen<bool>(
      shellTargetProvider.select((target) => target is CanvasTarget),
      (previous, selected) {
        if (!selected && immersiveIs(ImmersiveSurface.canvas)) {
          immersiveFullscreen.exit();
        }
      },
    );

    // 外层 LayoutBuilder 只负责"宽不宽"：悬浮按钮挂在 Scaffold 上，
    // 拿不到内层 SafeArea 里的约束，得在这里先判一次。
    return LayoutBuilder(
      builder: (context, viewport) {
        final wide = viewport.maxWidth >= kShellBreakpoint;

        // 真的按沉浸模式渲染的条件，按宿主分开判：
        // - 右栏标签：面板还在 + 标签是终端或预览；
        // - 中栏画布：当前中栏页仍是画布。
        // 只是"按过按钮"还不够：面板可能已经收起、标签或页面可能已经切走，
        // 那时候藏掉一切会得到一个空窗口。
        final panelImmersive =
            immersiveSurface == ImmersiveSurface.panel &&
            paneVisible &&
            canImmersive(activeTab);
        final canvasImmersive =
            immersiveSurface == ImmersiveSurface.canvas && canvasSelected;
        final immersive = wide && (panelImmersive || canvasImmersive);

        // 窄屏没有右栏，也就没有"面板吃掉中栏"这回事，整页形态自己会铺满。
        // 画布独占时面板全屏标记一律让位：一个要中栏铺满，一个要把中栏吃掉，
        // 同时成立只会得到一个没有画布的空屏（正常操作走不到，纯属兜底）。
        final fullscreen = wide && wantsFullscreen && !canvasImmersive;

        // 窗口被拖窄到单列布局：内容已经由整页面板铺满，沉浸模式没有意义，
        // 顺手把窗口还原。帧后执行——build 里不能改 provider。
        if (immersiveSurface != null && !wide) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            immersiveFullscreen.exit();
          });
        }

        return Scaffold(
          // 底色由主题决定：内置两套是纯色（不铺顶部渐变），主题包可自带染色。
          body: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              // 渐变只有一个出处：壳内的标签页只把 Scaffold 置透明，
              // 由这一层铺底（见 `AppPageScaffold`）。
              gradient: appSurfaceGradient(
                AppPalette.of(context),
                theme.colorScheme,
              ),
            ),
            child: Stack(
              children: <Widget>[
                // Esc 兜底：终端自己会先吃掉 Esc（见 `SshTerminalView`），事件不会
                // 冒泡到这里；真正落到这一层的是"焦点不在终端上"的情况
                // （连接表单、断开遮罩里的按钮）——那时也该能退出全屏。
                //
                // 这一层必须常驻：按 `immersive` 增删节点会把整棵骨架的 Element
                // 重新挂一遍，终端选区与滚动位置就跟着没了。
                Positioned.fill(
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (node, event) {
                      if (!immersive ||
                          event is! KeyDownEvent ||
                          event.logicalKey != LogicalKeyboardKey.escape) {
                        return KeyEventResult.ignored;
                      }
                      immersiveFullscreen.exit();
                      return KeyEventResult.handled;
                    },
                    child: SafeArea(
                      // macOS 隐藏了系统标题栏：宽屏这条自绘标题栏本来就要贴住窗口顶端
                      // （红绿灯浮在它的左端上空），再让 `SafeArea` 顶下来就整条掉到红绿灯下面了。
                      // 窄屏没有这条栏，内容才需要让开红绿灯。
                      // 其他平台照旧：手机要避开状态栏。
                      top: !(usesHiddenWindowTitleBar && wide),
                      bottom: false,
                      // 内容区离窗口顶多远：`SafeArea` 会把 padding/viewPadding 一起
                      // 清零，页头虚化带在它内部量不到这个值，只能在这里给一次。
                      child: ShellInsets(
                        top: MediaQuery.paddingOf(context).top,
                        child: LayoutBuilder(
                        builder: (context, constraints) {
                          // 骨架只切换 `Flex.direction`，不用 `Row`/`Column` 二选一：
                          // 两者 runtimeType 不同，跨断点时 Element 会被整棵销毁重建，
                          // `TerminalView` 与聊天页的 State 就会跟着重挂，选区、滚动位置
                          // 与键盘焦点全丢。换方向只是同一个 `Flex` 的 Element 原地更新。
                          // 宽屏有中栏：设置 / 录音 / 记忆都在中栏原地打开，
                          // 左栏不被盖住；窄屏没有中栏可占，仍整页推入。
                          final targets = ref.read(
                            shellTargetProvider.notifier,
                          );

                          /// 叫出中栏再切目标。
                          ///
                          /// 聊天浮窗 + 右栏同时在场时中栏是被隐藏的（见
                          /// `_WideContent.hideCenter`）：这时点左栏入口会"点了没反应"。
                          /// 浮窗先停靠回去，中栏才有地方显示新页面。
                          void revealPane() {
                            if (!wide) {
                              return;
                            }
                            final chat = ref.read(chatWindowProvider);
                            if (chat.floating &&
                                ref.read(filePaneVisibleProvider)) {
                              ref.read(chatWindowProvider.notifier).dock();
                            }
                          }

                          // 窄屏的「设置 / 录音笔记」已经是底部导航的一级标签：
                          // 这里切成标签，而不是再推一层整页——推上去会把导航条
                          // 整个盖掉，用户就回不到别的标签了。
                          // 宽屏的设置是浮层，不再占中栏：关掉之后聊天 / 项目 /
                          // 终端都留在原处，也不进后退栈。浮层里没有跳往别处的
                          // 入口——记忆 / 画布 / 录音笔记各有自己的左栏与导航入口。
                          void openSettings() {
                            if (wide) {
                              showSettingsDialog(context, session: session);
                              return;
                            }
                            ref
                                .read(narrowTabProvider.notifier)
                                .select(NarrowTab.profile);
                          }

                          void openRecordings() {
                            if (wide) {
                              revealPane();
                              targets.select(const RecordingsTarget());
                              return;
                            }
                            ref
                                .read(narrowTabProvider.notifier)
                                .select(NarrowTab.recordings);
                          }

                          void openCanvas() {
                            if (wide) {
                              revealPane();
                              targets.select(const CanvasTarget());
                              return;
                            }
                            openCanvasDemoPage(context);
                          }

                          void openMemory() {
                            if (wide) {
                              revealPane();
                              targets.select(const MemoryTarget());
                              return;
                            }
                            openMemoryPage(context);
                          }

                          // 左栏占位宽度只算一次：它同时决定中栏可用宽度和横线的起笔点，
                          // 两处各算一遍迟早会差一两个 dp，横线就接不上竖线了。
                          //
                          // 沉浸模式按 0 计（左栏整条不渲染），但**不写回**
                          // `railCollapsedProvider`：退出后左栏要回到用户原来的状态。
                          final railCollapsed = ref.watch(
                            railCollapsedProvider,
                          );
                          final railWidth = ref.watch(railWidthProvider);
                          final railTaken = immersive
                              ? 0.0
                              : _railTaken(
                                  collapsed: railCollapsed,
                                  railWidth: railWidth,
                                );

                          // 外层 `Column` 恒为一段：不按状态增删兄弟节点，
                          // 内层终端与聊天页就不会因索引变化重挂载。
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Expanded(
                                // 横线层包住**整个骨架**（左栏也在里面），不是只包中栏：
                                // 它按窗口坐标画，顶部那条要跨过栏缝、底部那条要跨过左栏，
                                // 都得以窗口左缘为原点。只包中栏的话画布 x=0 已经在中栏
                                // 左边，`centerLeft` 会被算两遍，两条线整体右移一条栏宽。
                                child: ShellDividers(
                                  // 沉浸模式里没有任何一条栏缝，也没有"页脚"可分隔。
                                  enabled: wide && !immersive,
                                  centerLeft: railTaken,
                                  footerVisible: !railCollapsed,
                                  // 骨架与聊天窗口叠在同一块可用区里：
                                  // 说话窗口要能压在任意一栏之上，就必须和骨架共享坐标系。
                                  // 横线层包在外面，所以停靠态的栏头横线仍然画在聊天窗口之上。
                                  child: Stack(
                                    fit: StackFit.passthrough,
                                    children: <Widget>[
                                      Flex(
                                        direction: wide
                                            ? Axis.horizontal
                                            : Axis.vertical,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        // 子节点个数恒为 2：宽窄切换、左栏收起都只替换第 0 个节点，
                                        // 绝不在这里追加分割线之类的额外兄弟节点（索引位移会重建内容区）。
                                        children: <Widget>[
                                          if (wide)
                                        // 沉浸模式只隐藏、不拆掉：`maintainState` 让导航树的
                                        // 滚动位置与展开状态留着，退出后原样回来。
                                        Visibility(
                                          visible: !immersive,
                                          maintainState: true,
                                          maintainAnimation: true,
                                          child: _ProjectRail(
                                            availableWidth:
                                                constraints.maxWidth,
                                            onOpenSettings: openSettings,
                                            onOpenRecordings: openRecordings,
                                            onOpenCanvas: openCanvas,
                                            onOpenMemory: openMemory,
                                          ),
                                        )
                                      else
                                        const _HeaderStack(),
                                      Expanded(
                                        // 面板全屏时左栏仍在（它自己那格照常渲染），
                                        // 只是中栏让位；具体怎么让位交给 `_WideContent`，
                                        // 免得这里多一个分支让内容区的 Element 换一次类型。
                                        child: wide
                                            ? _WideContent(
                                                fullscreen: fullscreen,
                                                immersive: panelImmersive,
                                                // 画布全屏：这一块反过来由中栏独占，
                                                // 右栏与拖动条让位。
                                                centerFill: canvasImmersive,
                                                // 右栏可用的宽度是「骨架宽度 - 左侧栏及其拖动条」。
                                                // 左栏收起时它不占位，可用宽度随之变大。
                                                availableWidth:
                                                    constraints.maxWidth -
                                                    railTaken,
                                                // 中栏左边界：停靠态聊天窗口从这一列起笔。
                                                railTaken: railTaken,
                                                pane: ShellPane(
                                                  session: session,
                                                  canvasImmersive:
                                                      canvasImmersive,
                                                ),
                                              )
                                            : NarrowTabs(session: session),
                                      ),
                                        ],
                                      ),
                                      // 聊天窗口层：会话视图在整个应用里只有这一份。
                                      // 层级在骨架之上、横线层之下——停靠时栏头那条横线
                                      // 才压得住它，浮起来之后它自己画一条。
                                      Positioned.fill(
                                        child: ChatWindowLayer(
                                          viewport: Size(
                                            constraints.maxWidth,
                                            constraints.maxHeight,
                                          ),
                                          wide: wide,
                                          railTaken: railTaken,
                                          // 两种全屏都让聊天让位：面板全屏与画布全屏
                                          // 的语义都是"这一块内容独占"，再压一块浮窗
                                          // 上去等于把刚放大的东西又切掉一角。
                                          fill: fullscreen || immersive,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      ),
                    ),
                  ),
                ),
                // 进入时的一次性提示：贴在窗口顶部，2.4s 后自动淡出。
                // 与骨架同层常驻，`visible` 变化只影响透明度，不重建终端。
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ImmersiveFullscreenHint(visible: immersive),
                  ),
                ),
                // 录音是全局状态：切页、切项目都不中断，所以状态条挂在
                // 骨架层而不是某个页面里。停止与回到录音页都从这里走。
                //
                // 窄屏底部压着导航胶囊：状态条要抬到它上面，否则两者叠在一起，
                // 「停止」按钮正好被胶囊吃掉。胶囊下沿固定在距底 16、不再叠加
                // 安全区（见 `NarrowTabBar`），这里也只按胶囊高度 + 8 抬升，
                // 否则两者之间会凭空多出一段安全区的空隙。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: wide ? 16 : kBottomNavClearance + 8,
                  child: Center(child: RecordingMiniBar(wide: wide)),
                ),
              ],
            ),
          ),
          // 窄屏的「新建项目」按钮不在这里：它只属于 Agent 标签，
          // 挂在骨架上会跟着切到记录 / 消息 / 我的时一起浮着（见 `narrow_tabs.dart`）。
          // 宽屏的入口在侧栏里（项目分组旁的 + 与新建会话）。
        );
      },
    );
  }
}

/// 左侧栏（含拖动条）实际占用的宽度。
double _railTaken({required bool collapsed, required double railWidth}) {
  if (collapsed) {
    return 0;
  }
  return railWidth + kRailHandleWidth;
}

/// 宽屏内容区：中间内容 + 可选的右侧栏。
///
/// 结构上恒定是三个槽位：中间区、拖动条、右栏。右栏开合与全屏都只替换槽里的内容，
/// 绝不增删兄弟节点——`Row` 按索引匹配 Element，删掉中间的槽会让右栏从 index 2
/// 滑到 index 1，`ProjectPanel → SshPage → TerminalView` 就会被整棵重建，
/// 终端选区、滚动位置一起丢。
class _WideContent extends ConsumerWidget {
  const _WideContent({
    required this.fullscreen,
    required this.immersive,
    this.centerFill = false,
    required this.availableWidth,
    required this.railTaken,
    required this.pane,
  });

  /// 面板全屏：面板吃掉中间区，左侧栏不受影响（它在上一层，不归这里管）。
  final bool fullscreen;

  /// 终端 / 预览全屏：比 [fullscreen] 更彻底——左栏已经被上一层藏掉了，
  /// 这里只需要把中间区、拖动条一起收成零尺寸，让面板独占整块宽度。
  final bool immersive;

  /// 画布全屏：与 [immersive] 正好相反——右栏（含拖动条）让位，
  /// 由中间区独占整块宽度。左栏同样已经被上一层藏掉了。
  final bool centerFill;

  /// 「中间内容 + 右侧栏」可用的总宽度（不含左侧栏）。
  final double availableWidth;

  /// 左栏连同它右侧拖动条占掉的宽度；左栏收起时为 0。
  ///
  /// 只为算中栏左边界（[ShellColumns.centerLeft]）而传进来：停靠态的聊天窗口
  /// 要从这一列起笔，跟中栏严丝合缝。
  final double railTaken;
  final Widget pane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 拖动条的底色要与右栏一致：它属于右栏，不是"缝隙"。
    final scheme = Theme.of(context).colorScheme;
    final visible = ref.watch(filePaneVisibleProvider);
    final width = ref.watch(filePaneWidthProvider);

    // 两种全屏都是"一整栏独占整块宽度"，只是一个让右栏吃、一个让中栏吃。
    final fill = fullscreen || immersive;

    // 宽度分配只认 `resolveShellColumns`：聊天窗口停靠时要拿到与中栏**完全一致**
    // 的矩形，两处各算一遍会差一两个 dp，左边就露出一条缝。
    final columns = resolveShellColumns(
      viewportWidth: availableWidth + railTaken,
      railTaken: railTaken,
      paneVisible: visible,
      paneWidth: width,
      fill: fill,
      centerFill: centerFill,
    );
    // 聊天浮窗显示时中栏没有内容可放：会话已经浮在上面，中栏留着的只是同一块
    // 聊天页的另一份（或一张空态），看起来像同时开了两个聊天。这一列直接让给右栏。
    //
    // 右栏收起时不让：那时"隐藏中栏"等于整块窗口只剩一个浮窗，用户没有别的东西
    // 可看，连把窗口拖回去的落点都没有。画布全屏时也不让：中栏就是画布。
    final chatFloating = ref.watch(
      chatWindowProvider.select((state) => state.floating),
    );
    final hideCenter = chatFloating && visible && !fill && !centerFill;

    final panelWidth = hideCenter ? columns.availableWidth : columns.panelWidth;
    // 非全屏时拖动条**恒挂**：面板收起之后也要留在树上（宽度压成 0），
    // 否则蓄力收起的那一刻它会被 dispose，手势随之中断——想从同一个手势里
    // 把面板拖回来就没戏了。零宽既不占位也接不到命中，视觉上等于不存在。
    // 中栏隐藏时也没有"两栏之间"这条线可拖。
    final showHandle = !fill && !centerFill && !hideCenter;

    // 面板状态是"打开"、但窗口已经放不下它的最小宽度：这时整栏根本画不出来。
    // 不在这里收起来的话，用户会陷入死路——入口（中栏按钮）因为 visible 为真而消失，
    // 面板又没出现，只能靠拉宽窗口自救。帧后改状态，避免在 build 里改 provider。
    // 画布全屏时右栏本来就让位成 0 宽（`centerFill`），不能在帧后把它
    // 真的收起来：退出全屏要按原来的状态原样摆回来。
    if (visible && !fill && !centerFill && panelWidth <= 0) {
      // 先把 notifier 取出来：帧后回调执行时这个 widget 可能已经被替换
      // （例如窗口继续变窄切到窄屏布局），那时再 `ref.read` 会抛"已 dispose"。
      final panes = ref.read(filePaneVisibleProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) => panes.hide());
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 槽 0：中间区。面板全屏 / 聊天浮窗时换成零尺寸占位（不是删掉）——见类注释。
        // 画布全屏正好相反：中栏留着并铺满，右栏让位。
        fill || hideCenter
            ? const SizedBox.shrink()
            : Expanded(child: pane),
        // 槽 1：拖动条。全屏时没有"中间区"可让，手柄也就没有意义。
        showHandle
            ? ShellResizeHandle(
                key: kFilePaneResizeHandleKey,
                // 面板收起时压成 0 宽：只为留住手势，不占位。
                // 与 `resolveShellColumns` 用同一个口径，聊天窗口的停靠宽度才不会差一条缝。
                width: columns.handleWidth,
                // 命中区并进右栏（与面板同色），线压在右栏左边界上。
                fillColor: paneSurfaceColor(scheme),
                lineSide: ResizeHandleLineSide.leading,
                // 右栏贴在右边：向左拖才是"拉回来"。
                reopenSign: -1,
                onHold: () => ref.read(filePaneVisibleProvider.notifier).hide(),
                onReopen: () =>
                    ref.read(filePaneVisibleProvider.notifier).show(),
                onDrag: (dx) {
                  // 右栏贴在右边：向左拖（dx 为负）才是变宽。
                  final current = ref.read(filePaneWidthProvider);
                  final raw = current - dx;

                  // 与左栏同一套口径：拖过下限只冻结宽度，收起要蓄力满半秒。
                  // 用未收敛的 raw 判断，不把小于下限的值写进 provider，
                  // 于是下次打开还是用户拖出来的那个宽度。
                  if (raw < kFilePaneMinWidth) {
                    return ResizeDragResult.atLimit;
                  }

                  final next = fitFilePaneWidth(
                    width: raw,
                    available: availableWidth,
                  );
                  if (next <= 0) {
                    // 窗口已经放不下这一栏：收起与否交给"面板放不下就自动隐藏"
                    // 那条兜底逻辑，不要在这里再蓄一次力。
                    return ResizeDragResult.resizing;
                  }

                  ref.read(filePaneWidthProvider.notifier).resize(next);
                  return ResizeDragResult.resizing;
                },
              )
            : const SizedBox.shrink(),
        // 槽 2：右栏。宽度为 0 时不建内容，避免在零宽约束里做一次没有意义的布局。
        SizedBox(
          width: panelWidth,
          // 左边缘不画边框：分隔线由它左边的拖动条提供（全屏时是左栏的拖动条）。
          child: panelWidth > 0
              ? ProjectPanel(
                  immersive: immersive,
                  // 面板吃掉中栏、且左栏也收起时，它的左边缘就是窗口左缘：
                  // 第一个标签要给 macOS 红绿灯让位。聊天浮窗把中栏让给右栏
                  // （`hideCenter`）是同一件事，只是没按"全屏"按钮。
                  flushLeft: (fill || hideCenter) && railTaken <= 0,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 窄屏顶部：只有 Agent 标签才有这一行（品牌标题 + 面板入口）。
///
/// 录音、消息、我的三页各自带 `AppBar`（「录音笔记」「消息」「设置」），
/// 再叠一条品牌行只会把内容顶下去、看着像两层页头。这也是原型的样子：
/// 01 是品牌页头，04/06/07 是各自页面的标题。
///
/// 槽位仍然常驻（父 `Flex` 子节点个数固定为 2，见 `HomeShell` 里那段注释），
/// 非 Agent 标签返回零高占位；只在这一处 watch 标签，切换时不会重建骨架。
class _HeaderStack extends ConsumerWidget {
  const _HeaderStack();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(narrowTabProvider);
    if (tab != NarrowTab.agent) {
      return const SizedBox.shrink();
    }

    return const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 智能体页的页头归外壳管（页面里没有 AppBar），走不了
        // `AppPageScaffold(frostTop:)` 那条通路；这里给它铺同一条顶部虚化带，
        // 五个标签页的顶端观感才一致。高度取页头本体——带子下面紧接着就是
        // 页面内容，伸出去会把列表首项糊了。
        //
        // 只是静态收口：内容仍停在页头下方、不会从它底下滚过。要穿透得把页头
        // 从这一列挪进页面内部，会牵动窄屏布局的第 0 个兄弟节点，暂不做。
        Stack(
          children: <Widget>[
            Positioned.fill(child: TopBarFade(height: kMobileTopBarMinHeight)),
            _Header(),
          ],
        ),
      ],
    );
  }
}

/// 左栏栏头：只有一条与窗口按钮同高的行，承载全部栏头按钮。
///
/// 标题「Jarvis」原本单独占第二行，现在删掉：左栏的身份由导航区
/// 自己承担，栏头只对窗口按钮负责，导航树因此整体上移 40dp。
///
/// macOS 下这一行就是窗口标题栏：红绿灯右侧到栏尾整段都能按住拖窗口；
/// 落在红绿灯上的点击归系统，不会传到这里。
///
/// 模式下拉已经删除：界面不再区分 CODE / WORK，右端不再需要一枚切换胶囊。
/// 剩下的导航按钮贴左，中间整段留白就是拖动区。系统全屏会把红绿灯收走
/// （`windowFullScreenProvider`），导航顺势贴到 12 的内容线上；退出全屏
/// 自动回到「红绿灯 + 导航」的排布。
///
/// 非 macOS 没有红绿灯行，这一行仍然必须存在——开合、后退、前进都要有落点，
/// 排布与 macOS 一致，只是左端不留红绿灯的空位。
class _RailHeader extends ConsumerWidget {
  const _RailHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 系统全屏会把红绿灯整组收走：给它们预留的 78dp 这时是块空地，
    // 按钮组顺势回到左端，与导航树落在同一条 12 的内容线上。
    // 退出全屏时 windowFullScreenProvider 变回 false，布局自动还原。
    final showTrafficLights =
        usesHiddenWindowTitleBar && !ref.watch(windowFullScreenProvider);

    const controls = <Widget>[
      RailToggleButton(),
      HistoryNavButtons(),
    ];

    // 首行左端的留白：有红绿灯（macOS 且未进系统全屏）时让开
    // `kMacWindowButtonsWidth`（78），否则回到 `kPaneContentInset`（12）
    // 的内容线——系统全屏把红绿灯整组收走，78 这时是块空地。
    //
    // 取值与中栏栏头共用 [paneHeaderLeadingLine]：两处各写一份数字时，
    // 左栏收起、按钮移交给中栏栏头的那一刻会横向跳几 dp。
    final leading = SizedBox(
      width: paneHeaderLeadingLine(reserveForTrafficLights: showTrafficLights),
      child: WindowDragArea(child: SizedBox.expand()),
    );

    if (!usesHiddenWindowTitleBar) {
      return SizedBox(
        height: kPaneHeaderHeight,
        child: Row(
          children: <Widget>[
            leading,
            ...controls,
            Expanded(child: WindowDragArea(child: SizedBox.expand())),
            const SizedBox(width: 6),
          ],
        ),
      );
    }

    return SizedBox(
      // 这一行就是窗口的标题栏：红绿灯由系统画在原生 32dp 的标题条里，
      // 本身比本行矮 8dp；原生侧会把三颗按钮下移 4dp 对齐本行中线
      // （见 `MainFlutterWindow.alignTrafficLights`），因此红绿灯与
      // 按钮组、中栏/右栏的栏头按钮同轴。双击缩放仍只认顶部那一条
      // （见 `window_chrome.dart`）。
      height: kPaneHeaderHeight,
      child: Row(
        children: <Widget>[
          leading,
          ...controls,
          Expanded(
            child: WindowDragArea(child: SizedBox.expand()),
          ),
          const SizedBox(width: kPaneEdgeInset),
        ],
      ),
    );
  }
}

/// 宽屏左侧栏：栏头按钮行、两行动作、导航树与底部账户行压成一列，
/// 内容区拿到剩余整块宽度。
///
/// 与 `_HeaderStack` 是同一层的替代品（同一个位置、只替换一个节点），
/// 父 `Flex` 的子节点个数因此始终是 2。
///
/// 收起时栏内容不构建，只留一条 0 宽的拖动条挂在原位：展开入口这时在中栏
/// 栏头左侧，栏不占内容区宽度。拖动条不摘是为了让"蓄力收起后反拖恢复"
/// 能用同一个手势完成（见 `ShellResizeHandle` 的注释）。
/// 面板全屏不关它的事——全屏只是让右栏吃掉中栏，导航树还得在。
class _ProjectRail extends ConsumerWidget {
  const _ProjectRail({
    required this.availableWidth,
    required this.onOpenSettings,
    required this.onOpenRecordings,
    required this.onOpenCanvas,
    required this.onOpenMemory,
  });

  /// 整个骨架的可用宽度，拖动分隔条时用它把宽度收敛到合理区间。
  final double availableWidth;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenRecordings;
  final VoidCallback onOpenCanvas;
  final VoidCallback onOpenMemory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(railCollapsedProvider);

    // 收起时**不再**直接 `return SizedBox.shrink()`：那样拖动条会被 dispose，
    // 蓄力收起的那一刻手势就断了，用户想往回拖也拉不回来（VS Code 能拉回来，
    // 靠的就是手势没断）。这里改成"栏内容不建、拖动条压成 0 宽留在树上"：
    // 布局仍占 0，横线起笔点（`_railTaken`）不用改；零宽不可命中，
    // 也不会变成第二个拖动入口。
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final railWidth = collapsed ? 0.0 : ref.watch(railWidthProvider);

    return Row(
      // 拉伸到整高：拖动条的命中区要跟着窗口高度走，
      // 否则 Row 默认的 center 对齐会让它只剩零高度，鼠标根本抓不到。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: railWidth,
          // 零宽时不建内容：在 0 宽约束里摆导航树既没有意义，也会溢出。
          child: railWidth <= 0
              ? null
              : Container(
                  decoration: BoxDecoration(
                    // 半透明而非实色：底下是整窗底色，实色会在顶部拉出一道硬边。
                    // 右边缘不画边框：那条分隔线由拖动条提供（见 `ShellResizeHandle`），
                    // 两处都画就是并排的两条。
                    color: paneSurfaceColor(scheme),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // 栏头只有按钮行：标题行删掉，搜索并入「项目」标题行。
                      // 左栏自上而下就是 按钮行 → 两行动作 → 导航树 → 账户行。
                      const _RailHeader(),
                      Expanded(
                        child: Padding(
                          // 只留 2dp：栏头下面直接接两行动作，不留一段空白。
                          padding: const EdgeInsets.only(top: 2),
                          child: RailNavigator(
                            onCreateProject: () =>
                                showCreateProjectDialog(context),
                            onOpenRecordings: onOpenRecordings,
                            onOpenCanvas: onOpenCanvas,
                          ),
                        ),
                      ),
                      // 底部只留一行账户入口：设置、记忆、退出登录都收进它的菜单。
                      // 原来这三行并排时，"记忆"的候选数字和"设置"一起被压到
                      // 导航树下面，既挤又像三个互不相关的页脚链接。
                      //
                      // 上方那条分隔线不在这里画：它要一直连到右侧的竖线（跨过 8dp
                      // 拖动条），由骨架层的 `ShellDividers` 统一画。
                      _RailAccountMenu(
                        onOpenSettings: onOpenSettings,
                        onOpenMemory: onOpenMemory,
                      ),
                    ],
                  ),
                ),
        ),
        ShellResizeHandle(
          key: kRailResizeHandleKey,
          // 收起时压成 0 宽：只为留住手势，视觉上与"整块让位"完全一样。
          width: collapsed ? 0 : kRailHandleWidth,
          // 命中区并进左栏（与栏同色），线压在左栏与中栏的边界上。
          fillColor: paneSurfaceColor(scheme),
          lineSide: ResizeHandleLineSide.trailing,
          // 左栏在左边：向右拖才是"拉回来"。
          reopenSign: 1,
          onHold: () => ref.read(railCollapsedProvider.notifier).collapse(),
          onReopen: () => ref.read(railCollapsedProvider.notifier).expand(),
          onDrag: (dx) {
            // 从 provider 读当前宽度而不是用 build 时的旧值：
            // 一帧里可能连续来几个 delta，只看旧值会丢掉一部分位移。
            final current = ref.read(railWidthProvider);
            final next = current + dx;

            // 拖过下限不算"收起"：收起要蓄力满半秒（见 `ShellResizeHandle`）。
            // 这里只把宽度冻在最后一个合法值——不写 260——收起只是"暂时不占位"，
            // 重新展开要回到用户拖出来的那个宽度。
            if (next < kRailMinWidth) {
              return ResizeDragResult.atLimit;
            }

            ref
                .read(railWidthProvider.notifier)
                .resize(clampRailWidth(width: next, available: availableWidth));
            return ResizeDragResult.resizing;
          },
        ),
      ],
    );
  }
}

/// 左栏底部的账户入口：头像 + 用户名，点开是设置 / 记忆 / 退出登录。
///
/// 参考 Claude 的账户行：底部只留一个"我"的入口，低频项全收进菜单。
/// 原来记忆 / 录音笔记 / 设置三行并排时，把它们各自当成页脚链接，
/// 既占掉导航树的高度，又和"低频但全局"的定位对不上。
///
/// 浮层用项目通用的 [AgentMenu]：贴着窗口底部时 `MenuAnchor` 会在布局阶段
/// 自动翻到触发器上方，这里不自己算方向。
class _RailAccountMenu extends ConsumerWidget {
  const _RailAccountMenu({
    required this.onOpenSettings,
    required this.onOpenMemory,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onOpenMemory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    // 列表还在加载时按 0 处理：候选数只是提示，晚一帧出现不会误导。
    final candidates = ref.watch(memoryCandidatesCountProvider);
    // 记忆在宽屏是"中栏里的一页"：入口行跟着高亮。设置不再占中栏（它是浮层），
    // 浮层开关与菜单选中态无关，所以这里只认记忆。
    final target = ref.watch(shellTargetProvider);
    final selected = target is MemoryTarget;

    return SizedBox(
      // 行高仍是 40：骨架层按这个高度画底部横线，收窄的只是触发器本身。
      height: kPaneHeaderHeight,
      child: Padding(
        // 与导航行的左右边缘对齐；触发器只占内容宽度，右侧留白不参与命中。
        padding: const EdgeInsets.fromLTRB(
          kPaneContentInset,
          0,
          kPaneEdgeInset,
          0,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AgentMenu<String>(
            width: AgentMenuStyle.panelMinWidth,
            groups: <AgentMenuGroup<String>>[
              AgentMenuGroup<String>(
                items: <AgentMenuItem<String>>[
                  AgentMenuItem<String>(
                    value: 'settings',
                    label: '设置',
                    icon: Icons.settings_outlined,
                    key: kRailAccountSettingsKey,
                  ),
                  AgentMenuItem<String>(
                    value: 'memory',
                    label: '记忆',
                    icon: Icons.psychology_outlined,
                    key: kRailAccountMemoryKey,
                    // 三位数会把菜单行撑开，与旧底部行的口径一致取 99+。
                    badge: candidates > 0
                        ? (candidates > 99 ? '99+' : '$candidates')
                        : null,
                  ),
                  AgentMenuItem<String>(
                    value: 'signOut',
                    label: '退出登录',
                    icon: Icons.logout_rounded,
                    key: kRailAccountSignOutKey,
                    // 破坏性/不可逆的项与上面隔一条线，避免顺手点错。
                    dividerBefore: true,
                  ),
                ],
              ),
            ],
            onSelected: (value) {
              switch (value) {
                case 'settings':
                  onOpenSettings();
                case 'memory':
                  onOpenMemory();
                default:
                  // 退出登录还没接：只给一句提示，不能假装已经登出。
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text('退出登录即将支持'),
                        duration: Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
              }
            },
            builder: (context, controller, open, hovering) => Semantics(
              key: kRailAccountMenuKey,
              button: true,
              label: '账户菜单，$kAccountDisplayName',
              // 与输入栏的「权限」胶囊同构：宽度由内容决定，悬停底只包住内容。
              // 原来整行铺满的灰块更像一个"页脚"，而不像一个能点开的东西。
              child: AgentMenuTriggerSurface(
                height: 32,
                padding: const EdgeInsets.only(left: 4, right: 6),
                highlighted: open || hovering || selected,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      // 只是一个底：不描边。加了边之后 22 的圆里再扣掉 1px
                      // 边框，字母会被挤小，反而比缩尺寸更难看。
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.surfaceContainerHighest,
                      ),
                      child: Center(
                        child: Text(
                          kAccountDisplayName.substring(0, 1).toUpperCase(),
                          style: TextStyle(
                            fontSize: AppFontSize.sm,
                            height: AppLineHeight.tight,
                            fontWeight: AppWeight.semiBold,
                            color: palette.text.secondary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      kAccountDisplayName,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: AppFontSize.base,
                        height: AppLineHeight.tight,
                        fontWeight: AppWeight.medium,
                        color: palette.text.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // 方向走 `AgentMenuChevron` 的默认（收起朝下、展开朝上）：
                    // 三处入口统一，不各自传图标。
                    AgentMenuChevron(open: open, size: kPaneHeaderIconSize),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 窄屏标题行：品牌标题 + 新建项目 + 面板入口。
///
/// 原先右侧还排着记忆、录音、画布、设置四枚图标；底部导航接管录音与设置后，
/// 记忆与画布挪进了「我的」。剩下的两枚里，「新建项目」是 Agent 这一页的主操作
/// （原来在右下角做成悬浮按钮，滚动时飘在列表上；挪到页头后位置固定），
/// 面板入口不属于任何标签（面板是"看这台机器的文件与终端"，与一级页都不同族），
/// 所以留在页头。新按钮插在面板入口左侧，不改变它的位置。
///
/// 尺寸按手机端原型：内边距 12 / 8 / 上下 12 / 4 + 38dp 玻璃圆钮 = 54 的最小高度。
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kMobileTopBarSideInset,
        12,
        kMobileTopBarEndInset,
        4,
      ),
      child: Row(
        children: <Widget>[
          // 标题独占剩余宽度，入口才能贴住右边缘。别写成
          // `Flexible(标题) + Spacer()`：两者都是 flex:1，而 Flexible 是 loose 的，
          // 标题没用完的那份不会再给 Spacer，入口看起来就像"没右对齐"。
          Expanded(
            child: Text(
              'Jarvis',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mobileTopBarTitleStyle(context),
            ),
          ),
          // 两枚动作并成一枚胶囊：各带一层玻璃时，交界处会看到两条折射边缘
          // 叠在一起，像胶囊中间裂了条缝。组内每格只留命中区与水波纹。
          MobileTopBarButtonGroup(
            children: <Widget>[
              MobileTopBarButton(
                bare: true,
                icon: Icons.add,
                tooltip: '新建项目',
                onPressed: () => showCreateProjectDialog(context),
              ),
              const PanelEntryButton(mobile: true, bare: true),
            ],
          ),
        ],
      ),
    );
  }
}
