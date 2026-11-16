import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/browser/browser_controller.dart';
import '../../core/browser/browser_models.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/file_preview_kind.dart';
import '../../core/preview_source.dart';
import '../../core/ssh/ssh_controller.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_icon_button.dart';
import '../../core/window_chrome.dart';
import '../browser/browser_pane.dart';
import '../browser/browser_zoom_shortcuts.dart';
import '../git/git_pane.dart';
import '../preview/preview_kind_icon.dart';
import '../ssh/ssh_page.dart';
import 'chat_float_icon.dart';
import 'chat_window_state.dart';
import 'file_pane_state.dart';
import 'file_preview_view.dart';
import 'panel_fullscreen.dart';
import 'panel_fullscreen_icon.dart';
import 'panel_start_icon.dart';
import 'panel_start_view.dart';
import 'panel_tab_menu.dart';
import 'pane_surface.dart';
import 'shell_dividers.dart';
import 'shell_layout_state.dart';
import 'sidebar_toggle_icon.dart';
import 'window_fullscreen.dart';
import 'project_file_pane.dart';

/// 右侧栏外壳：首行标签栏（40dp = 标签 26 + 上下各 7）+ 当前标签的内容。
///
/// 右栏被定位成「通用工作面板」而不是文件树：开始页是常驻的首页，
/// 项目文件与终端是两个并列的能力，后面的浏览器按同一套标签扩展。
///
/// 宽屏是浮在中栏右侧的一栏；窄屏没有这一栏，由 [PanelPage] 以整页形式复用它，
/// 那时 [standalone] 为 true：只有"返回"，全屏与隐藏让位给整页布局
/// （整页本身就占满屏幕，再提供一次全屏只会是个按了没反应的按钮）。
class ProjectPanel extends ConsumerWidget {
  const ProjectPanel({
    super.key,
    this.standalone = false,
    this.immersive = false,
    this.flushLeft = false,
  });

  /// 整页形态（窄屏）。只影响栏头按钮的语义，不影响标签与内容。
  final bool standalone;

  /// 终端全屏（沉浸模式）：连标签栏一起藏掉，只留终端内容本身。
  ///
  /// 由 `HomeShell` 传进来而不是在这里读 provider：窄屏整页面板也复用这个
  /// 组件，而整页形态本来就不进沉浸模式，读同一份全局状态容易误伤。
  final bool immersive;

  /// 本面板的左边缘就是窗口左缘。
  ///
  /// 只有这时第一个标签会与 macOS 红绿灯抢位置，需要留出
  /// `kMacWindowButtonsWidth`。三种情况会成立：窄屏整页、面板全屏、
  /// 以及聊天浮窗把中栏让给右栏（此时左栏再收起，面板就一路贴到窗口左边）。
  ///
  /// 由装配方判定而不是在栏内猜 provider：栏自己拿不到"我离窗口左缘多远"，
  /// 而漏判的后果正是红绿灯压住第一个标签。
  final bool flushLeft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tab = ref.watch(filePaneTabProvider);

    // 切换项目（或切模式把目标清空）时，旧目录的展开状态与预览都不再有意义。
    ref.listen(shellTargetProvider, (previous, next) {
      // 工具页（录音 / 设置 / 记忆）没有项目归属：中栏换了一页而已，
      // 右栏那个项目的树与预览应当原样留着。
      if (next != null && next.projectId.isEmpty) {
        return;
      }
      if (previous?.projectId == next?.projectId) {
        return;
      }
      ref.read(filePaneExpandedProvider.notifier).collapseAll();
      ref.read(filePaneTabProvider.notifier).resetForProject();
    });

    // 关掉最后一个标签 = 这一栏已经没有内容可显示：宽屏收起整栏，
    // 窄屏整页没有"隐藏"按钮，等价地退回上一页。
    //
    // 状态层只把标签列表清空、不直接改显隐：显隐是界面层的决定，
    // 两个 provider 互相读写会在"隐藏 → 补页 → 又显示"之间绕圈。
    ref.listen(filePaneTabProvider.select((state) => state.tabs.isEmpty), (
      previous,
      empty,
    ) {
      if (!empty || previous == true) {
        return;
      }
      // 帧后执行：build 里不能改 provider。回调跑起来时本 widget 可能已经
      // 不在树上，所以先把 notifier 与 navigator 取出来。
      final panes = ref.read(filePaneVisibleProvider.notifier);
      final navigator = Navigator.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (standalone) {
          navigator.maybePop();
        } else {
          panes.hide();
        }
      });
    });

    return Container(
      decoration: BoxDecoration(
        // 半透明而非实色：底下是随模式变化的渐变，实色会在顶部拉出一道硬边。
        // 左边缘不画分隔线：宽屏下它由左边的拖动条提供（见 `ShellResizeHandle`），
        // 两处都画就会在 8dp 栏缝两侧各出一条。
        color: paneSurfaceColor(scheme),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 沉浸模式里标签栏换成零尺寸占位：`Column` 仍是两个子节点，
          // 下面那个 `Expanded` 的索引不动，`IndexedStack` 与终端不会被重挂。
          _PanelTabBar(
            state: tab,
            standalone: standalone,
            flushLeft: flushLeft,
            hidden: immersive,
          ),
          Expanded(
            child: _PanelContent(
              state: tab,
              standalone: standalone,
              immersive: immersive,
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板内容：常驻栈，而不是 `AnimatedSwitcher`。
///
/// 浏览器是平台视图：切走标签时若被销毁，回来会整页重载、丢失滚动与表单状态；
/// 终端、预览同理。`IndexedStack` 让每个已打开的标签保持挂载，只切可见性。
/// 代价是打开过的标签都会占内存，换来的是"切回来还是刚才那一眼"。
class _PanelContent extends StatelessWidget {
  const _PanelContent({
    required this.state,
    required this.standalone,
    required this.immersive,
  });

  final FilePaneTabState state;
  final bool standalone;

  /// 终端全屏：透传给终端页，让它把自己的状态栏与快捷键条一起藏掉。
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final tabs = state.orderedTabs;
    if (tabs.isEmpty) {
      return const SizedBox.shrink();
    }

    var index = tabs.indexWhere(state.isTabActive);
    if (index < 0) {
      index = 0;
    }

    return IndexedStack(
      index: index,
      sizing: StackFit.expand,
      children: <Widget>[
        for (final tab in tabs)
          KeyedSubtree(
            // 空白页、预览与浏览器都是多实例的：key 里带 id，同一个位置换页面时
            // 才会真的换内容（而不是把旧 WebView 直接复用到新标签上）。
            key: ValueKey<String>('panel-content-${tab.kind.name}-${tab.id}'),
            child: _build(tab),
          ),
      ],
    );
  }

  Widget _build(PanelTabRef tab) {
    return switch (tab.kind) {
      // 空白页知道自己是谁：从这里点功能是"在这张页上打开"，不是再开一个新标签。
      FilePaneTab.start => PanelStartView(tabId: tab.id),
      FilePaneTab.files => const ProjectFilePane(),
      // 沉浸模式与终端共用：面板里只剩内容本身，文件头让位。
      FilePaneTab.preview => _previewBody(tab.id),
      FilePaneTab.terminal => SshPage(
        // 宽屏浮层里，终端铺在中栏位置上，左/右栏开合按钮是唯一
        // 还能调整布局的入口；整页面板里栏根本不存在，不给。
        showPaneToggles: !standalone,
        allowFullscreen: !standalone,
        immersive: immersive,
      ),
      // 缩放的快捷键要"看得到这一页"才生效：宿主跟着浏览器标签一起挂，
      // 切到文件 / 终端 / 预览时原生那边立刻恢复不吞键。
      FilePaneTab.browser => BrowserZoomShortcutHost(
        child: BrowserPane(tabId: tab.id),
      ),
      // 提交审查：变更 / 历史 / diff / 提交框。git 命令在服务端跑。
      FilePaneTab.git => const GitPane(),
    };
  }

  /// 预览标签的内容：来源表里有记录就按来源构造，没有就按"项目文件、
  /// 项目取当前 shell 目标"的老口径（文件树打开的标签都是这条）。
  Widget _previewBody(String tabId) {
    final source = state.previewSourceOf(tabId);
    final asset = source?.asset;
    if (asset != null) {
      return FilePreviewView(
        path: asset.id,
        asset: asset,
        conversationTitle: source!.conversationTitle,
        immersive: immersive,
      );
    }
    return FilePreviewView(
      path: tabId,
      projectId: source?.projectId ?? '',
      immersive: immersive,
    );
  }
}

class _PanelTabBar extends ConsumerStatefulWidget {
  const _PanelTabBar({
    required this.state,
    required this.standalone,
    required this.flushLeft,
    required this.hidden,
  });

  final FilePaneTabState state;

  /// 整页形态：关闭 → 返回上一页，且不出现栏内开合/全屏按钮。
  final bool standalone;

  /// 本栏左边缘就是窗口左缘：要给红绿灯留位置。
  final bool flushLeft;

  /// 终端全屏：整条栏不渲染（不建标签、不装右键菜单），只留内容。
  final bool hidden;

  @override
  ConsumerState<_PanelTabBar> createState() => _PanelTabBarState();
}

class _PanelTabBarState extends ConsumerState<_PanelTabBar> {
  /// 整条标签栏共用一个菜单锚点。
  ///
  /// 早先是"每个标签一个 MenuAnchor"：N 个常驻 OverlayPortal，父级每次重建
  /// 都要重建 N 份菜单树与菜单项的 CurvedAnimation。右键落点本身就能反算出
  /// 点的是哪个标签，所以只留一个锚点，菜单内容按命中的标签临时算。
  final MenuController _menuController = MenuController();

  /// 右键命中的标签；null 表示还没右键过（此时菜单内容为空，不会被打开）。
  PanelTabRef? _menuAnchor;

  /// 右键落点，相对标签栏的局部坐标——`MenuController.open` 要的就是这个。
  Offset _menuPosition = Offset.zero;

  /// 右键落到第几个标签上。
  ///
  /// 标签是定宽排布，落点减掉第一个标签之前的占位（全屏收栏时让给红绿灯那一段，
  /// 手机版还有「返回」与它后面那道缝）即可反算；落在右侧拖动区或工具按钮上时
  /// 返回 null，不弹标签菜单。
  void _handleSecondaryTapDown(
    TapDownDetails details, {
    required double tabWidth,
    required int count,
    required double insetBeforeTabs,
  }) {
    final index = panelTabIndexAt(
      dx: details.localPosition.dx - insetBeforeTabs,
      tabWidth: tabWidth,
      count: count,
    );
    final ordered = widget.state.orderedTabs;
    if (index == null || index >= ordered.length) {
      return;
    }

    // 先记锚点、帧末再开：菜单项（尤其「关闭」是否置灰）取决于被点的是哪个
    // 标签，得让下一次 build 用新锚点生成内容，否则菜单会先闪一帧旧状态。
    // 这一帧（约 16ms）远小于被去掉的 200ms 高亮动画，手感上察觉不到。
    setState(() {
      _menuAnchor = ordered[index];
      _menuPosition = details.localPosition;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _menuController.open(position: _menuPosition);
    });
  }

  /// 菜单里选中动作后的执行：先把"要关谁"算清，再一次性交给状态层。
  ///
  /// 用 `ref.read` 取最新状态而不是 build 时的快照：菜单从弹出到选中之间
  /// 可能隔着一次项目切换，用旧快照会算出已经消失的标签。
  void _runTabAction(PanelTabMenuAction action) {
    final anchor = _menuAnchor;
    if (anchor == null) {
      return;
    }

    final latest = ref.read(filePaneTabProvider);
    _closeTargets(switch (action) {
      PanelTabMenuAction.close => <PanelTabRef>[anchor],
      PanelTabMenuAction.closeOthers => latest.otherTabs(anchor),
      PanelTabMenuAction.closeLeft => latest.tabsBefore(anchor),
      PanelTabMenuAction.closeRight => latest.tabsAfter(anchor),
    });
  }

  /// 一次关掉一批标签：先收会话，再做状态迁移。
  ///
  /// 右键菜单与「更多」菜单共用这一条路径：关标签等于放弃这台 shell，与标签上的
  /// 关闭叉同一条规则；各写一份迟早会漏掉某一处的会话释放。
  ///
  /// 终端用 `discardSession` 而不是 `disconnect`：后者会把状态停在「已断开」，
  /// 下次打开终端看到的是这台旧终端的残骸，而不是一张干净的连接表单。
  /// 浏览器按 id 逐个释放：桥接监听、静态服务与 WebView 都要一起收掉，
  /// 不能把回环端口留在后台。
  void _closeTargets(List<PanelTabRef> targets) {
    if (targets.isEmpty) {
      return;
    }
    if (targets.any((tab) => tab.kind == FilePaneTab.terminal)) {
      ref.read(sshControllerProvider.notifier).discardSession();
    }
    ref.read(filePaneTabProvider.notifier).closeTabs(targets);
    for (final tab in targets) {
      if (tab.kind == FilePaneTab.browser) {
        _releaseBrowserSession(tab.id);
      }
    }
  }

  /// 「更多」菜单选中后的执行：切标签走 `activate`，批量关闭走 [_closeTargets]。
  ///
  /// 与 [_runTabAction] 一样用 `ref.read` 取最新状态：菜单从弹出到选中之间
  /// 可能隔着一次项目切换，用 build 时的快照会算出已经消失的标签。
  void _runMoreSelection(PanelTabMoreSelection selection) {
    switch (selection) {
      case PanelTabMoreSwitch(:final id):
        ref.read(filePaneTabProvider.notifier).activate(id);
      case PanelTabMoreClose(:final action):
        final latest = ref.read(filePaneTabProvider);
        final active = latest.activeTab;
        _closeTargets(switch (action) {
          // 「关闭其他」以**当前**标签为锚点：这个菜单不是从某个标签上弹出的，
          // 用户说的"其他"就是"除了我正在看的这张"。
          PanelTabMoreAction.closeOthers =>
            active == null ? const <PanelTabRef>[] : latest.otherTabs(active),
          PanelTabMoreAction.closeAll => latest.orderedTabs,
        });
    }
  }

  /// 关闭一个浏览器标签：先收标签，再释放它的会话。
  void _closeBrowserTab(String id) {
    ref.read(filePaneTabProvider.notifier).closeBrowserTab(id);
    _releaseBrowserSession(id);
  }

  /// 释放某个浏览器标签的会话（桥接监听、静态服务、WebView 一起收）。
  ///
  /// 等这一帧重建完再失效，而不是立刻失效：标签还在栏上时它仍有订阅者
  /// （[_BrowserTab] 在 watch 这个 id），`invalidate` 会当场重建出一个空会话，
  /// 而控制器 `build()` 里的 `keepAlive` 会把它永久留下——id 单调不回收，
  /// 等于每关一个标签就攒一份幽灵状态。等标签从集合里移除、订阅消失后再失效，
  /// 这次失效就退化成纯销毁，`onDispose` 里把通道收干净。
  ///
  /// 用 container 而不是 `ref.invalidate`：回调跑在下一帧，那时本 widget
  /// 可能已经不在树上（比如面板被收起）。
  void _releaseBrowserSession(String id) {
    final container = ProviderScope.containerOf(context, listen: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      container.invalidate(browserSessionProvider(id));
    });
  }

  /// 关闭一个非浏览器标签。
  ///
  /// 关终端标签等于放弃这台 shell：释放连接，别把会话留在后台无人使用
  /// （SSH 凭据与 shell 都是最不该残留的东西）。这里用 `discardSession` 而不是
  /// `disconnect`：状态要回到 idle，下次打开终端才是连接表单，而不是一台
  /// 已经断开的旧终端。全屏属于面板、不属于某个标签，所以关标签不改布局
  /// （否则全屏看终端的人一关标签就被弹回三栏）。
  void _closeTab(PanelTabRef tab) {
    if (tab.kind == FilePaneTab.terminal) {
      ref.read(sshControllerProvider.notifier).discardSession();
    }
    ref.read(filePaneTabProvider.notifier).closeTab(tab);
  }

  /// 标签图标。颜色由标签自己按选中态给（见 [_PanelTabState._icon]）。
  ///
  /// 空白页那枚是指南针：参考图里它叫「开始」，也是 Material `explore`
  /// 的写法（实心针），这里换成自绘的线性版，见 [PanelStartIcon]。
  Widget _tabIcon(PanelTabRef tab, Color color) {
    final iconSize = kPanelTabIconSize;
    return switch (tab.kind) {
      FilePaneTab.start => PanelStartIcon(size: iconSize, color: color),
      FilePaneTab.files => Icon(
        Icons.folder_outlined,
        size: iconSize,
        color: color,
      ),
      FilePaneTab.terminal => Icon(
        Icons.terminal_rounded,
        size: iconSize,
        color: color,
      ),
      // 预览按文件类型换图标：一排标签里"哪张是图、哪份是 PDF"只看名字
      // 认不出来（尤其文件名被压窄成省略号时）。会话产物的 tab id 是
      // `media:<id>`，扩展名不参与判断，得按来源取图标。
      FilePaneTab.preview => Icon(
        _previewIcon(tab.id),
        size: iconSize,
        color: color,
      ),
      // 浏览器标签走 [_BrowserTab]（标题与图标跟着页面走），不会到这里。
      FilePaneTab.browser => Icon(
        Icons.language_outlined,
        size: iconSize,
        color: color,
      ),
      // 分叉线：一眼区分"改了这个仓库"与"看这个目录"。
      FilePaneTab.git => Icon(
        Icons.call_split_rounded,
        size: iconSize,
        color: color,
      ),
    };
  }

  /// 预览标签的图标：会话产物按资产类型，项目文件按扩展名。
  IconData _previewIcon(String tabId) {
    final asset = ref.read(filePaneTabProvider).previewSourceOf(tabId)?.asset;
    if (asset != null) {
      return asset.isImage ? Icons.image_outlined : Icons.movie_outlined;
    }
    if (PreviewSource.looksLikeMediaTab(tabId)) {
      return Icons.image_outlined;
    }
    return previewIconOf(previewKindOf(tabId));
  }

  /// 标签上的文字。
  ///
  /// 空白页叫「新标签页」：连点几次「+」会同时挂好几张，名字要能表达
  /// "这里还没选功能"，而不是让人以为每张都叫「开始」。
  String _tabLabel(FilePaneTabState state, PanelTabRef tab) {
    return switch (tab.kind) {
      FilePaneTab.start => kPanelBlankTabLabel,
      FilePaneTab.files => '文件',
      FilePaneTab.terminal => '终端',
      FilePaneTab.preview => state.previewTitle(tab.id),
      FilePaneTab.browser => '浏览器',
      FilePaneTab.git => 'Git',
    };
  }

  String _tabCloseTooltip(FilePaneTab kind) {
    return switch (kind) {
      FilePaneTab.files => '关闭文件标签',
      FilePaneTab.terminal => '关闭终端标签',
      FilePaneTab.preview => '关闭预览标签',
      FilePaneTab.start => '关闭标签页',
      FilePaneTab.browser => '关闭浏览器标签',
      FilePaneTab.git => '关闭 Git 标签',
    };
  }

  /// 「更多」菜单的全部内容：上面是标签清单，下面是两个批量关闭动作。
  ///
  /// 标签名与图标不在这里另起一套：直接复用 [_tabLabel] / [_tabIcon]，
  /// 菜单只是"同一份命名的第二种呈现"。预览标签的名字来自
  /// `state.previewTitle`，搬去别处就会和标签栏各算各的。
  List<AgentMenuGroup<PanelTabMoreSelection>> _moreMenuGroups(
    FilePaneTabState state,
  ) {
    final palette = AppPalette.of(context);
    final active = state.activeTab;
    return <AgentMenuGroup<PanelTabMoreSelection>>[
      AgentMenuGroup<PanelTabMoreSelection>(
        items: <AgentMenuItem<PanelTabMoreSelection>>[
          for (final tab in state.orderedTabs)
            AgentMenuItem<PanelTabMoreSelection>(
              key: panelMoreTabKey(tab.id),
              value: PanelTabMoreSwitch(tab.id),
              // 自绘的「开始」图标没法用 `IconData` 表达，所以统一走 `leading`。
              leading: _tabIcon(
                tab,
                state.isTabActive(tab)
                    ? palette.text.primary
                    : palette.text.secondary,
              ),
              label: _tabLabel(state, tab),
              selected: state.isTabActive(tab),
            ),
        ],
      ),
      AgentMenuGroup<PanelTabMoreSelection>(
        // 分割线把"去哪儿"和"关哪些"分开：下面两项都会改变当前标签集合，
        // 和上面的跳转混成一片时很容易误点。
        dividerBefore: true,
        items: <AgentMenuItem<PanelTabMoreSelection>>[
          AgentMenuItem<PanelTabMoreSelection>(
            key: kPanelTabMoreCloseOthersKey,
            value: const PanelTabMoreClose(PanelTabMoreAction.closeOthers),
            icon: Icons.clear_all_rounded,
            label: '关闭其他标签页',
            // 只剩一张时没有"其他"可关：与右键菜单同一条口径，直接置灰。
            enabled: active != null && state.otherTabs(active).isNotEmpty,
          ),
          AgentMenuItem<PanelTabMoreSelection>(
            key: kPanelTabMoreCloseAllKey,
            value: const PanelTabMoreClose(PanelTabMoreAction.closeAll),
            icon: Icons.layers_clear_rounded,
            label: '关闭全部标签页',
            // 含当前标签：关完这一栏就没有内容，界面层据此收起右栏。
            enabled: state.tabs.isNotEmpty,
          ),
        ],
      ),
    ];
  }

  /// 「更多」按钮：触发器的开合自己管。
  ///
  /// 用 `triggerHandlesTap: false`：`AgentMenu` 默认会在触发器外面再套一层点击，
  /// 而这里是一个自带 `onPressed` 的 `IconButton`，两层都管就会"一次点击既开又关"。
  Widget _buildMoreMenu(
    FilePaneTabState state, {
    bool mobile = false,
    bool bare = false,
  }) {
    return AgentMenu<PanelTabMoreSelection>(
      // 与标签右键菜单同宽：两个浮层都从这一带弹出，宽度不一致会看着跳一下。
      width: AgentMenuStyle.panelMinWidth,
      alignment: AlignmentDirectional.bottomStart,
      triggerHandlesTap: false,
      groups: _moreMenuGroups(state),
      onSelected: _runMoreSelection,
      builder: (context, controller, open, hovering) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (mobile) {
          return MobileTopBarButton(
            key: kPanelMoreMenuKey,
            bare: bare,
            compact: true,
            icon: Icons.format_list_bulleted_rounded,
            tooltip: '更多标签页',
            onPressed: toggle,
          );
        }
        return IconButton(
          key: kPanelMoreMenuKey,
          tooltip: '更多标签页',
          onPressed: toggle,
          style: _barButtonStyle,
          iconSize: kPaneHeaderIconSize,
          // 清单图标：这个按钮给出的就是"全部标签的名单"，而不是"再多几个动作"。
          // 与左栏视图菜单用同一枚字形，栏头几枚图标的笔触也更接近。
          icon: const Icon(Icons.format_list_bulleted_rounded),
        );
      },
    );
  }

  /// 栏内小按钮（全屏 / 隐藏 / 返回 / 更多 / 新建标签页）共用样式。
  ///
  /// 形状由 [shellIconButtonStyle] 统一成 8dp 圆角方形：悬停底要和旁边
  /// 那些圆角标签是一套轮廓，而不是一圈正圆。
  static final ButtonStyle _barButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  @override
  Widget build(BuildContext context) {
    // 终端全屏：整条标签栏让位给终端内容。
    //
    // 这里是"早退"而不是把整棵子树包进 `Visibility`：标签栏上有 `MenuAnchor`、
    // 一排 `InkWell` 与悬停状态，藏起来还留着它们既没意义，也会让右键菜单
    // 在不可见的坐标里弹出来。早退只会让本 widget 变成零尺寸，
    // 父级 `Column` 的两个子节点、下面的 `IndexedStack` 都不受影响。
    if (widget.hidden) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final state = widget.state;
    final standalone = widget.standalone;
    // 整页（手机版）是这条栏唯一的窄屏形态：40 高的标签条塞不下 38 圆钮，
    // 这里改用紧凑版（30 / 16），上下留白收到 4；标签本身仍是 26 高。
    final mobileBar = standalone;
    final fullscreen = ref.watch(panelFullscreenProvider);
    // 全屏时聊天窗口默认让位，工具条里那枚按钮负责把它叫出来。
    final peek = ref.watch(
      chatWindowProvider.select((state) => state.peekInFullscreen),
    );
    final hasChat =
        ref.watch(chatWindowProvider.select((state) => state.pinned != null)) ||
        ref.watch(shellTargetProvider) is ConversationTarget;
    final tabs = ref.read(filePaneTabProvider.notifier);

    // 「更多」只在标签多到需要管理时才出现。
    //
    // 两张以内的标签一眼看得完，多挂一个按钮只会白吃掉标签宽度；三张起标签
    // 开始被压窄、名字被截断，"去哪儿"本身就变难了，这时才值得多一个入口。
    final showMore = state.tabs.length > 2;

    // macOS 红绿灯那一块：留白而不是塞按钮，与左栏栏头的处理一致。
    //
    // 判断依据是装配方给的 [ProjectPanel.flushLeft]——"本面板左边缘就是窗口左缘"。
    // 在栏内拼 provider（全屏 + 左栏收起 + standalone）漏过一种常见组合：
    // 聊天浮窗把中栏让给右栏、左栏再收起，面板同样一路贴到窗口左边，
    // 但 `panelFullscreenProvider` 是 false，于是第一个标签正压在红绿灯上。
    //
    // 窗口已进系统全屏时红绿灯被系统收走，留白只会白吃标签宽度。
    final leadingInset =
        usesHiddenWindowTitleBar &&
            !ref.watch(windowFullScreenProvider) &&
            widget.flushLeft
        ? kMacWindowButtonsWidth
        : 0.0;

    // 第一个标签左侧实际被占掉的宽度：红绿灯留白，手机版还要加上「返回」与它
    // 后面那道缝。右键菜单按落点反算标签下标，起点必须与真实排布一致。
    final tabsStart =
        leadingInset +
        (mobileBar ? kMobileTopBarCompactSize + kPanelTabGap : 0.0);

    // 宽屏浮层里的栏头横线由骨架层的 `ShellDividers` 画（它要跨过 8dp 拖动条
    // 才能接上中栏工具栏那条线）；窄屏整页没有那一层，仍由标签栏自己画。
    final shellDividers = ShellDividerScope.isActive(context);

    // 标签栏直接按列表渲染：列表顺序就是插入顺序（打开 / 原地转换时的位置）。
    // 浏览器标签单独包一层（见 [_BrowserTab]），其余共用 [_PanelTab]。
    final tabWidgets = <Widget>[
      for (final tab in state.tabs)
        if (tab.kind == FilePaneTab.browser)
          _BrowserTab(
            key: panelBrowserTabKey(tab.id),
            id: tab.id,
            active: state.isTabActive(tab),
            onTap: () => tabs.activate(tab.id),
            onClose: () => _closeBrowserTab(tab.id),
          )
        else
          _PanelTab(
            key: panelTabKey(tab),
            icon: (color) => _tabIcon(tab, color),
            label: _tabLabel(state, tab),
            active: state.isTabActive(tab),
            onTap: () => tabs.activate(tab.id),
            closeTooltip: _tabCloseTooltip(tab.kind),
            onClose: () => _closeTab(tab),
          ),
    ];

    // 当前标签的下标：它左右两侧的缝里不画接缝线（见 [_PanelTabDivider]）。
    final activeIndex = state.tabs.indexWhere(state.isTabActive);

    // 菜单内容跟着"右键命中的标签"和最新标签集合走；还没右键过时为空。
    final anchor = _menuAnchor;
    final menuItems = anchor == null
        ? const <AgentMenuItem<PanelTabMenuAction>>[]
        : tabMenuItems(state: state, anchor: anchor);

    return Container(
      // 与左栏栏头、中栏工具栏同高：三栏按钮落在同一条水平线上。
      height: kPaneHeaderHeight,
      // 纵向留白写在这里而不是留给"栏高恰好比标签高一点"：标签高度是
      // `kPanelTabHeight`，栏高是它加上下各 [kPaneHeaderVerticalPadding]，
      // 于是标签上下间距由结构保证，改标签字号/内边距也不会把它吃掉。
      // 本栏自己画横线时，底部留白要扣掉它的粗细：边框占的是 `height` 里的
      // 1dp，不扣的话标签会被压短 1dp，上下留白就一边 7 一边 6。
      // 横向走三栏统一的栏级内边距：左侧贴着分隔线，要扣掉那 8dp 栏缝。
      padding: EdgeInsets.fromLTRB(
        kPaneEdgeInset,
        // 手机版：30 的紧凑圆钮要塞进 40 高的标签条，上下留白收到 4。
        mobileBar ? 4 : kPaneHeaderVerticalPadding,
        kPaneContentInset,
        // 不画 border 时把它的 1dp 还给底部留白：标签上下仍是各 7dp，
        // 不会因为少一条线而往上偏半像素。
        mobileBar
            ? 4 - (shellDividers ? 0 : kPaneHeaderBorderWidth)
            : shellDividers
            ? kPaneHeaderVerticalPadding
            : kPaneHeaderVerticalPadding - kPaneHeaderBorderWidth,
      ),
      decoration: shellDividers
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: kPaneHeaderBorderWidth,
                  color: shellDividerColor(scheme),
                ),
              ),
            ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 右侧按钮先占位，标签只能拿剩下的宽度：
          // 少时每个保底 96、最多 180；多到装不下就按剩余宽度平分。
          //
          // 手机版：「返回」在最左、「+」在最右，返回 30 与它右侧那道缝一起算。
          final actionsWidth = mobileBar
              ? kMobileTopBarCompactSize + kPanelTabGap
              : kPaneHeaderButtonSize * 2;
          // 「+」与「更多」在手机版是 30 的圆钮，扣的宽度要跟着换，
          // 否则标签会按 24 算出来再把 Row 撑破。
          final addSize = mobileBar
              ? kMobileTopBarCompactSize
              : kPanelTabAddButtonSize;
          // 手机版把「更多 + 新建」并成一枚胶囊，两格之间多出的 1dp 分隔线也是
          // 实打实占宽；不计进去，360 宽的屏上定宽标签会把 Row 撑破。
          final groupDivider = mobileBar && showMore
              ? kMobileTopBarGroupDividerWidth
              : 0.0;
          final width = panelTabWidth(
            // 红绿灯留白、「更多」/「+」两个按钮与「+」前面那道缝都是实打实
            // 被占掉的宽度：不扣掉，标签就会按整栏宽算出来再把 Row 撑破
            // （标签是定宽 SizedBox，挤不回去）。
            available:
                constraints.maxWidth -
                // 本行的左右内边距同样是实打实被占掉的宽度。
                kPaneEdgeInset -
                kPaneContentInset -
                actionsWidth -
                leadingInset -
                // 「更多」只在三张及以上时存在，藏起来时不能扣它的宽度，
                // 否则两张标签时右边会多出一段莫名其妙的空白。
                (showMore ? addSize : 0) -
                addSize -
                // 「+」前面那道缝只在非手机版存在：手机版的「+」贴在栏最右，
                // 它前面的空白由 `Expanded` 的拖动区兜着，不占标签的预算。
                (mobileBar ? 0.0 : kPanelTabGap) -
                groupDivider,
            count: tabWidgets.length,
          );

          // 整条标签栏一个锚点：右键按下时按落点反算命中的标签，
          // 记下锚点后在帧末打开（见 `_handleSecondaryTapDown`）。
          return AgentMenu<PanelTabMenuAction>(
            controller: _menuController,
            width: AgentMenuStyle.panelMinWidth,
            // 按坐标弹出：面板左上角就落在右键落点上，不再额外偏移。
            alignmentOffset: Offset.zero,
            // 触发器是整条标签栏（只接管右键），点击不该由组件抢。
            triggerHandlesTap: false,
            groups: <AgentMenuGroup<PanelTabMenuAction>>[
              AgentMenuGroup<PanelTabMenuAction>(items: menuItems),
            ],
            onSelected: _runTabAction,
            // 按坐标弹出时锚点只代表"刚才点的地方"，再点它应当收起菜单。
            consumeOutsideTap: true,
            builder: (context, controller, open, hovering) => GestureDetector(
              // 只接管次要键；主键仍交给各标签自己的 InkWell。
              behavior: HitTestBehavior.translucent,
              onSecondaryTapDown: (details) => _handleSecondaryTapDown(
                details,
                tabWidth: width,
                count: tabWidgets.length,
                insetBeforeTabs: tabsStart,
              ),
              child: Row(
                children: <Widget>[
                  // macOS 红绿灯那一块：留白而不是塞按钮，与左栏栏头的处理一致；
                  // 空白本身包成拖动区，收起左栏后仍能在标签栏左端按住拖窗口。
                  if (leadingInset > 0)
                    SizedBox(
                      width: leadingInset,
                      child: const WindowDragArea(child: SizedBox.expand()),
                    ),
                  // 手机版：返回在最左，排在第一个标签之前。它与其它页头的返回
                  // 是同一枚自绘 chevron，只是收到紧凑版。
                  if (mobileBar) ...<Widget>[
                    const MobileTopBarBackButton(compact: true),
                    const SizedBox(width: kPanelTabGap),
                  ],
                  for (var i = 0; i < tabWidgets.length; i++) ...<Widget>[
                    // 分隔线占的正是原来那条 4dp 缝：宽度算法不用跟着改。
                    // 第 i 根线在标签 i 左侧，贴着当前标签（i == activeIndex
                    // 或 i == activeIndex + 1）的那两根不出线。
                    if (i > 0)
                      _PanelTabDivider(
                        index: i,
                        visible: i != activeIndex && i != activeIndex + 1,
                      ),
                    SizedBox(width: width, child: tabWidgets[i]),
                  ],
                  // 非手机版：「+」紧跟最后一个标签——新建的空白页由用户自己挑
                  // 功能，保证"新开一页"这个动作永远在同一处，不用先去别的页里
                  // 找入口。它占的宽度已经在上面的 `available` 里扣掉了。
                  //
                  // 「更多」贴在「+」左侧：两者都是"标签栏本身"的动作，
                  // 右边的全屏/隐藏属于面板，不该混在一起。
                  if (!mobileBar) ...<Widget>[
                    const SizedBox(width: kPanelTabGap),
                    if (showMore) _buildMoreMenu(state),
                    IconButton(
                      key: kPanelNewTabKey,
                      tooltip: '新标签页',
                      onPressed: () => ref
                          .read(filePaneTabProvider.notifier)
                          .openNewTabPage(),
                      style: _barButtonStyle,
                      iconSize: kPaneHeaderIconSize,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                  // 标签右侧的空白也是栏头的一部分：macOS 下按住可拖动窗口。
                  const Expanded(
                    child: WindowDragArea(child: SizedBox.expand()),
                  ),
                  // 手机版：「更多 + 新建」贴在栏最右，与左侧的「返回」分踞两端。
                  // 这两枚 30 的圆钮本来就贴在一起，并成一枚胶囊：各自带一层玻璃
                  // 会在交界处叠出两条折射边缘，像胶囊裂了缝。
                  if (mobileBar) ...<Widget>[
                    if (showMore)
                      MobileTopBarButtonGroup(
                        compact: true,
                        children: <Widget>[
                          _buildMoreMenu(state, mobile: true, bare: true),
                          MobileTopBarButton(
                            key: kPanelNewTabKey,
                            bare: true,
                            compact: true,
                            icon: Icons.add_rounded,
                            tooltip: '新标签页',
                            onPressed: () => ref
                                .read(filePaneTabProvider.notifier)
                                .openNewTabPage(),
                          ),
                        ],
                      )
                    else
                      MobileTopBarButton(
                        key: kPanelNewTabKey,
                        compact: true,
                        icon: Icons.add_rounded,
                        tooltip: '新标签页',
                        onPressed: () => ref
                            .read(filePaneTabProvider.notifier)
                            .openNewTabPage(),
                      ),
                  ],
                  if (!standalone) ...<Widget>[
                    // 全屏时把聊天窗口临时叫出来。放在「退出全屏」前面：
                    // 两枚都是"这一屏显示什么"的动作，挨着才顺手。
                    // 没有聊天窗口（中栏是项目 / 空态）时这一枚不出现，
                    // 免得点了什么都看不见。
                    if (fullscreen && hasChat)
                      IconButton(
                        key: kChatFloatPeekKey,
                        tooltip: peek ? '收起聊天浮窗' : '聊天浮窗',
                        onPressed: () => ref
                            .read(chatWindowProvider.notifier)
                            .setPeekInFullscreen(!peek),
                        style: _barButtonStyle,
                        iconSize: kPaneHeaderIconSize,
                        icon: ChatFloatIcon(
                          size: kPaneHeaderIconSize,
                          // 叫出来之后保持高亮：回答"这块浮窗是谁点开的"。
                          color: peek ? scheme.primary : null,
                        ),
                      ),
                    // 全屏在工具条里，而不是塞进终端状态栏：面板里的文件、预览同样值得满屏。
                    IconButton(
                      key: kFilePaneFullscreenKey,
                      tooltip: fullscreen ? '退出全屏' : '全屏',
                      onPressed: () =>
                          ref.read(panelFullscreenProvider.notifier).toggle(),
                      style: _barButtonStyle,
                      iconSize: kPaneHeaderIconSize,
                      // 两态各一枚字形，都照 Codex：未全屏是对角两段括号，
                      // 已全屏换成朝内、小一号的两枚短箭。
                      icon: PanelFullscreenIcon(
                        size: kPaneHeaderIconSize,
                        fullscreen: fullscreen,
                      ),
                    ),
                    // 只有一个"关掉面板"的入口：中栏那个开合按钮在面板打开时已经让位，
                    // 这里用同一枚侧栏图标表达"把这一栏收回去"。
                    IconButton(
                      key: kFilePaneHideKey,
                      tooltip: '隐藏右侧栏',
                      onPressed: () =>
                          ref.read(filePaneVisibleProvider.notifier).hide(),
                      style: _barButtonStyle,
                      iconSize: kPaneHeaderIconSize,
                      icon: const SidebarToggleIcon(
                        mirrored: true,
                        size: kPaneHeaderIconSize,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 一个浏览器标签：名字与图标都跟着页面走。
///
/// 单独包一层是因为标题与 favicon 存在 `browserSessionProvider(id)` 里：
/// 让每个浏览器标签各自订阅自己的会话，页面加载时只有这一个标签重建，
/// 不会带着整条标签栏一起刷。
class _BrowserTab extends ConsumerWidget {
  const _BrowserTab({
    super.key,
    required this.id,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  final String id;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(browserSessionProvider(id));
    return _PanelTab(
      icon: (color) =>
          Icon(Icons.language_outlined, size: kPanelTabIconSize, color: color),
      favicon: session.favicon,
      label: browserTabLabel(session),
      active: active,
      onTap: onTap,
      closeTooltip: '关闭浏览器标签',
      onClose: onClose,
    );
  }
}

/// 面板标签：图标 + 名字（+ 关闭叉）。
///
/// 宽度由父级按「可用宽度 ÷ 标签数」算好后塞进 `SizedBox`，这里不再自己收约束：
/// 宽度稳定下来，切标签时整条栏才不会跟着文字长短左右跳。
class _PanelTab extends StatefulWidget {
  const _PanelTab({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.favicon,
    this.onClose,
    this.closeTooltip,
  });

  /// 占位图标。没有 favicon（或 favicon 解不出来）时显示它。
  ///
  /// 做成「给颜色、返回 widget」的回调，是因为空白页那枚指南针要自绘
  /// （Material 里没有空心针的写法），而颜色只有在标签里按选中态才知道。
  final Widget Function(Color color) icon;

  /// 站点图标字节。浏览器标签才有值，其它标签一律用 [icon]。
  final Uint8List? favicon;

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  /// 关闭按钮的 tooltip。不按标签名自动拼，是因为测试与其他入口都按它定位，
  /// 文案一改就会全线失配。
  final String? closeTooltip;

  @override
  State<_PanelTab> createState() => _PanelTabState();
}

class _PanelTabState extends State<_PanelTab> {
  /// 鼠标是否停在本标签上。非当前标签只在这时露出关闭叉。
  bool _hovering = false;

  /// 关闭叉的悬停底圆角：按栏头那套「24 见方 → 8 圆角」同比例缩放。
  ///
  /// 写死 5 只是"看着差不多"，槽位一旦再改宽窄就对不上；用比例算出来，
  /// 16 见方得到 5.33，观感与栏头按钮的圆角是同一档。
  static final double _tabCloseRadius =
      kShellIconButtonRadius * kPanelTabCloseSize / kPaneHeaderButtonSize;

  /// 关闭叉的悬停底：贴合标签内的 16 见方槽位，圆角按比例缩放。
  static final ButtonStyle _tabCloseStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPanelTabCloseSize),
    radius: _tabCloseRadius,
  );

  /// 站点图标本身解码失败（拿到的是 HTML 或损坏的图）时退回占位图标：
  /// `errorBuilder` 是唯一能兜住这种情况的地方，不能让标签直接显示破图。
  Widget _icon(ColorScheme scheme) {
    final color = widget.active ? scheme.onSurface : scheme.onSurfaceVariant;
    final fallback = widget.icon(color);
    final bytes = widget.favicon;
    if (bytes == null || bytes.isEmpty) {
      return fallback;
    }
    return Image.memory(
      bytes,
      width: kPanelTabIconSize,
      height: kPanelTabIconSize,
      // 同一张图在多个标签间共享同一份字节，换标签时不必重新淡入。
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 当前标签常显关闭叉（"我在看它，随时能关"）；其它标签悬停才出现，
    // 免得一条栏上挂满叉号，把标签名挤成省略号。
    final showClose = widget.active || _hovering;
    final hasClose = widget.onClose != null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          // 这里不注册右键回调：整条栏共用一个菜单锚点，右键事件冒泡到
          // `_PanelTabBar` 的 GestureDetector 统一处理（谁被点由坐标反算）。
          borderRadius: BorderRadius.circular(AppRadius.sm),
          hoverColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            // 与栏高推导同源：栏高 - 上下留白 = 这个高度，标签正好铺满可视行高。
            height: kPanelTabHeight,
            // 右侧只留 2dp：关闭槽自己带内边距，叉号要贴住标签右边缘。
            padding: EdgeInsets.only(left: 8, right: hasClose ? 4 : 8),
            decoration: BoxDecoration(
              // 选中用实底 + 描边 + 一点阴影：Codex 的标签条就是靠这三件套
              // 在浅灰栏底上区分"现在在看哪一个"，而不是靠色块重量。
              //
              // 非选中态给的是"同色 0 透明度"而不是 null/透明黑：切标签时
              // 颜色要做插值，经透明黑会先闪一下深色边和深色底。
              color: scheme.surface.withValues(alpha: widget.active ? 1 : 0),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: scheme.outlineVariant.withValues(
                  alpha: widget.active ? 0.6 : 0,
                ),
              ),
              boxShadow: widget.active
                  ? <BoxShadow>[
                      BoxShadow(
                        color: scheme.onSurface.withValues(alpha: 0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: kPanelTabIconSize,
                  height: kPanelTabIconSize,
                  child: _icon(scheme),
                ),
                const SizedBox(width: 5),
                // 名字占满中间，关闭槽固定贴右：文字短的时候叉也不会飘到中间。
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: AppFontSize.sm,
                      fontWeight: widget.active
                          ? AppWeight.semiBold
                          : AppWeight.medium,
                      color: widget.active
                          ? AppPalette.of(context).text.primary
                          : AppPalette.of(context).text.secondary,
                    ),
                  ),
                ),
                if (hasClose)
                  // 用 `square` 而不是只给 width：标签这一行的高度是 24，
                  // 只锁宽的槽位会让按钮被行高拉成竖条，悬停底就成了窄长的胶囊。
                  SizedBox.square(
                    dimension: kPanelTabCloseSize,
                    // 槽宽常驻、只切换透明度：悬停时插入按钮会让文字被挤窄、
                    // 整条标签抖一下。
                    child: IgnorePointer(
                      ignoring: !showClose,
                      child: AnimatedOpacity(
                        opacity: showClose ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        // 关闭叉的悬停底比栏头那批小一号：图标仍是 11 号，
                        // 底框收到槽宽 16 见方，圆角按 8:24 同比例缩到 5.33；
                        // 直接用 8 的话，16 的方块上会圆得接近正圆。
                        child: IconButton(
                          tooltip: widget.closeTooltip ?? '关闭标签',
                          onPressed: widget.onClose,
                          style: _tabCloseStyle,
                          iconSize: 11,
                          color: scheme.onSurfaceVariant,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 标签之间的浅灰竖线（参考 Codex 的标签条）。
///
/// 画在原来那条 [kPanelTabGap] 缝里、不额外占宽度：标签宽度是按
/// `available - kPanelTabGap * (count - 1)` 算出来的，线一旦占位，
/// `panelTabWidth` 与"切标签时整条栏不跳"的约束都得跟着改。
/// 只有标签之间才画，标签栏两端不画——两端已经有栏本身的边界。
///
/// 当前标签左右两侧的那两根不画：槽位照留（宽度不变），只是不着色，
/// 于是高亮的标签框旁边不会多出一条像描边的灰线，切标签时整条栏也不跳。
class _PanelTabDivider extends StatelessWidget {
  const _PanelTabDivider({required this.index, required this.visible});

  /// 分隔线在第几个标签之前（从 1 开始）。用来给每根线一个独立的 Key。
  final int index;

  /// 是否着色。`false` 时只留 [kPanelTabGap] 的空槽，不出线。
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      // 槽宽沿用标签之间的缝，线本身只有 1px、垂直居中。
      width: kPanelTabGap,
      child: visible
          ? Center(
              child: Container(
                key: panelTabDividerKey(index),
                width: kPanelTabDividerWidth,
                height: kPanelTabDividerHeight,
                decoration: BoxDecoration(
                  // 比栏底分隔线更淡一档：它只是"页签的接缝"，不该抢过当前标签的描边。
                  color: scheme.outlineVariant.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(0.5),
                ),
              ),
            )
          : null,
    );
  }
}
