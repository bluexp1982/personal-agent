import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/models.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/shell_icon_button.dart';
import '../../core/project_providers.dart';
import '../conversations/chat_page.dart';
import '../conversations/conversations_page.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/new_conversation_action.dart';
import '../shell/pane_surface.dart';
import '../shell/section_actions.dart';
import '../shell/selection_toolbar.dart';
import '../shell/shell_layout_state.dart';
import '../tasks/create_task_action.dart';
import '../tasks/tasks_page.dart';
import 'project_actions.dart';

/// 项目详情：一个项目下的会话与任务。
///
/// 两级视图（会话 / 任务）用 Tab 而不是两个入口：它们同属一个项目，
/// 分开成两个页面只会让人反复横跳。
class ProjectDetailPage extends ConsumerStatefulWidget {
  const ProjectDetailPage({
    super.key,
    required this.project,
    this.embedded = false,
    this.onOpenConversation,
    this.onOpenTask,
    this.onClose,
    this.onDeleted,
  });

  final Project project;

  /// 嵌在宽屏右侧栏里时不画返回按钮（没有可返回的上一页）。
  final bool embedded;

  /// 会话 / 任务的"打开"动作交给外层：宽屏下右侧原地切换。
  final ValueChanged<ConversationSummary>? onOpenConversation;
  final ValueChanged<String>? onOpenTask;

  /// 关闭（收起）这个项目时的收尾。宽屏下由外壳把右侧切回空状态，
  /// 项目本身仍留在侧栏；整页形态没有传，就按"返回上一页"处理。
  final VoidCallback? onClose;

  /// 删除成功后的收尾。宽屏下由外壳清空右侧，而不是 pop 一个不存在的路由。
  final VoidCallback? onDeleted;

  @override
  ConsumerState<ProjectDetailPage> createState() =>
      _ProjectDetailPageState();
}

class _ProjectDetailPageState extends ConsumerState<ProjectDetailPage>
    with SingleTickerProviderStateMixin {
  late Project _project = widget.project;
  bool _busy = false;

  /// Tab 与工具动作合并成一行后，头部要按当前 Tab 取对应的动作，
  /// 所以这里自己持有 TabController，而不是交给 `DefaultTabController`。
  late final TabController _tabs = TabController(length: 2, vsync: this);

  /// 两个子页各自把「管理 / 刷新」写进来，合并行按 `_tabs.index` 取一个。
  final SectionActionsController _conversationActions =
      SectionActionsController();
  final SectionActionsController _taskActions = SectionActionsController();
  late final Listenable _sectionBar = Listenable.merge(<Listenable>[
    _tabs,
    _conversationActions,
    _taskActions,
  ]);

  @override
  void dispose() {
    _tabs.dispose();
    _conversationActions.dispose();
    _taskActions.dispose();
    super.dispose();
  }

  /// 重命名：对话框与请求都在 [renameProject] 里，这里只管把本页缓存换成新名字。
  ///
  /// 重命名成功后侧栏也要立刻换名：`renameProject` 会失效 `projectsProvider`，
  /// 不需要本页再补一次。
  Future<void> _rename(Project current) async {
    final renamed = await renameProject(context, ref, current);
    if (renamed == null || !mounted) {
      return;
    }
    setState(() => _project = renamed);
  }

  /// 页头「新建」：会话 Tab 建一条会话，任务 Tab 派一件事。
  ///
  /// 两个动作都走各自的公共实现，宽窄屏的差别只在"建完怎么打开"：
  /// 宽屏交给外壳切中栏；窄屏是压在骨架之上的整页路由，得自己 push 一页，
  /// 只改 `shellTargetProvider` 用户看不到。
  Future<void> _createForTab(Project project) async {
    if (_tabs.index == 0) {
      final created = await createConversation(context, ref, host: project);
      if (created == null || !mounted || widget.embedded) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            conversationId: created.id,
            title: created.title,
            projectPath: project.path,
            projectId: project.id,
            // 标题在会话页里被改（手动或自动生成）就立刻换掉本页缓存。
            onRenamed: (_) => ref.invalidate(conversationsProvider(project.id)),
          ),
        ),
      );
      return;
    }

    final taskId = await createTask(
      context,
      ref,
      projectId: project.id,
      mode: project.mode,
      projectPath: project.path,
      onOpenTask: widget.onOpenTask,
    );
    if (!mounted || taskId == null) {
      return;
    }
    ref.invalidate(tasksProvider(project.id));
    ref.invalidate(projectProvider(project.id));
  }

  /// 关闭项目：只把"正在看"的这一栏收起来，不删数据、不动侧栏列表。
  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    // 整页形态（窄屏 push 上来的）没有外壳托底：等同于返回。
    Navigator.of(context).maybePop();
  }

  /// 删除项目：确认 → 请求 → 收尾。
  ///
  /// 忙碌态在**确认之后**才点亮：把"等用户点确定"也算进加载，菜单会先消失，
  /// 用户会以为已经删掉了。请求失败时 [deleteProject] 已弹过 SnackBar，
  /// 这里只把忙碌态还回去。
  Future<void> _delete(Project current) async {
    final confirmed = await confirmDeleteProject(context, current);
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _busy = true);
    final deleted = await deleteProject(context, ref, current);
    if (!mounted) {
      return;
    }
    if (!deleted) {
      setState(() => _busy = false);
      return;
    }
    // 内嵌形态没有"上一页"可回：交给外壳把右侧切回空状态。
    if (widget.embedded) {
      widget.onDeleted?.call();
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 列表页 / 会话 / 任务都会改变计数，这里跟着 provider 走，不需要手动 refresh。
    final live =
        ref.watch(projectProvider(_project.id)).value ?? _project;
    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：内嵌时底色由骨架的渐变透上来。
      // Tab 里的会话/任务列表也是半透明（各自 Scaffold），这里不铺就成了两层白。
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded
          ? paneSurfaceColor(Theme.of(context).colorScheme)
          : null,
      body: Column(
        children: <Widget>[
          // 页头的「新建」跟着 Tab 变（建会话 / 派任务），所以要跟着
          // TabController 重建；这一行只有 54dp 内容，逐帧重建的成本可忽略。
          AnimatedBuilder(
            animation: _tabs,
            builder: (context, _) => _Header(
              project: live,
              busy: _busy,
              embedded: widget.embedded,
              tabIndex: _tabs.index,
              onClose: _close,
              onRename: () => _rename(live),
              onDelete: () => _delete(live),
              onCreate: () => _createForTab(live),
            ),
          ),
          // Tab 与「管理 / 刷新」合并成一行：原来两条行只留一条，
          // 列表因此多出一行的高度。
          AnimatedBuilder(
            animation: _sectionBar,
            builder: (context, _) => _SectionBar(
              controller: _tabs,
              actions: _tabs.index == 0
                  ? _conversationActions.value
                  : _taskActions.value,
              conversationCount: live.conversationCount,
              taskCount: live.taskCount,
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                ConversationsPage(
                  projectId: live.id,
                  mode: live.mode,
                  projectPath: live.path,
                  embedded: true,
                  onOpenConversation: widget.onOpenConversation,
                  actionsController: _conversationActions,
                ),
                TasksPage(
                  projectId: live.id,
                  mode: live.mode,
                  projectPath: live.path,
                  embedded: true,
                  // 窄屏页头已经有「新建」圆钮，底部不再重复一枚悬浮按钮；
                  // 宽屏中栏页头没有这个入口，仍保留它。
                  showCreateFab: widget.embedded,
                  onOpenTask: widget.onOpenTask,
                  actionsController: _taskActions,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 项目的头部：左边是「会话 / 任务」Tab，右边是当前视图的工具动作。
///
/// 两者原本是上下两行，合并后与栏头同高（40dp），底部只留一条细线：
/// 选中标签的下划线正好压在这条线上。
class _SectionBar extends StatelessWidget {
  const _SectionBar({
    required this.controller,
    required this.actions,
    required this.conversationCount,
    required this.taskCount,
  });

  final TabController controller;

  /// 当前 Tab 对应的动作。未激活的子页还没 build 时为空，这一帧先空着。
  final SectionActions? actions;
  final int conversationCount;
  final int taskCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = AppPalette.of(context).accent;

    return Container(
      height: kPaneHeaderHeight,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          // 可滚动 TabBar 必须有宽度约束，否则会在 Row 里拿不到有界宽。
          Expanded(
            child: TabBar(
              controller: controller,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              // 底线由外层画，这里再画一条就成了双线。
              dividerHeight: 0,
              // 左右 12 + 外层 4，让首个标签文字与下方列表卡片的 16dp 左边缘对齐。
              padding: const EdgeInsets.only(left: 4),
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              labelColor: accent.projectTint,
              unselectedLabelColor: scheme.onSurfaceVariant,
              indicatorColor: accent.projectTint,
              indicatorSize: TabBarIndicatorSize.label,
              indicatorWeight: 2,
              splashBorderRadius: BorderRadius.circular(AppRadius.sm),
              labelStyle: const TextStyle(
                fontSize: AppFontSize.base,
                fontWeight: AppWeight.semiBold,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: AppFontSize.base,
                fontWeight: AppWeight.medium,
              ),
              // 底线占 1dp，标签高度要把它让出来，否则 Row 会被顶破。
              tabs: <Widget>[
                Tab(
                  height: kPaneHeaderHeight - kPaneHeaderBorderWidth,
                  text: '会话 $conversationCount',
                ),
                Tab(
                  height: kPaneHeaderHeight - kPaneHeaderBorderWidth,
                  text: '任务 $taskCount',
                ),
              ],
            ),
          ),
          if (actions != null) _SectionActionsView(actions: actions!),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// 合并行右侧的工具动作：非管理态是「管理 / 刷新」两枚图标按钮，
/// 管理态是「全选 / 完成」两枚文字按钮。
///
/// 行高只有 40dp，所有按钮都要按栏头那套紧凑尺寸收紧，否则会把行撑破。
/// 「管理」收成图标是为了和紧挨着的「刷新」同一视觉重量：一个图标一个文字
/// 并排时，文字按钮会显得比旁边的图标重。
class _SectionActionsView extends StatelessWidget {
  const _SectionActionsView({required this.actions});

  final SectionActions actions;

  static final ButtonStyle _compactText = TextButton.styleFrom(
    minimumSize: const Size(0, 28),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(
      fontSize: AppFontSize.md,
      fontWeight: AppWeight.medium,
    ),
  );

  /// 「管理 / 刷新」两枚按钮共用栏头规格：命中区 24、8dp 圆角方形悬停底。
  static final ButtonStyle _iconButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  @override
  Widget build(BuildContext context) {
    if (actions.managing) {
      // `SelectionAppBarActions` 里是默认 40dp 高的 TextButton，
      // 用主题把它们压到 28dp；AppBar 那条路径不受影响。
      return TextButtonTheme(
        data: TextButtonThemeData(style: _compactText),
        child: SelectionAppBarActions(
          selectedCount: actions.selectedCount,
          selectableCount: actions.selectableCount,
          onToggleAll: actions.onToggleAll,
          onDone: actions.onDone,
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (actions.canManage)
          IconButton(
            tooltip: '管理',
            onPressed: actions.onManage,
            style: _iconButtonStyle,
            iconSize: kPaneHeaderIconSize,
            // 勾选清单：这一栏的"管理"就是切进多选态，别用铅笔之类
            // 会被理解成"编辑标题"的字形。
            icon: const Icon(Icons.checklist_rounded),
          ),
        IconButton(
          tooltip: '刷新',
          onPressed: actions.onRefresh,
          style: _iconButtonStyle,
          iconSize: kPaneHeaderIconSize,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }
}

/// 项目页头：与聊天/任务页共用同一条 34/36dp 紧凑栏头。
///
/// 不再画整块模式渐变：模式身份收进一个小徽标，项目名与路径在同一行，
/// 操作全部进「更多」菜单，避免头图比内容还抢眼。
class _Header extends ConsumerWidget {
  const _Header({
    required this.project,
    required this.busy,
    required this.embedded,
    required this.tabIndex,
    required this.onClose,
    required this.onRename,
    required this.onDelete,
    required this.onCreate,
  });

  final Project project;
  final bool busy;

  /// 内嵌时不画返回箭头：宽屏中栏没有可返回的路由栈。
  final bool embedded;

  /// 当前 Tab：0 会话、1 任务。页头那枚「新建」随它换图标与文案。
  final int tabIndex;
  final VoidCallback onClose;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onCreate;

  /// 页头「…」的样式：与同一行其它栏头按钮同构（命中区 24 / 圆角方形）。
  static final ButtonStyle _menuButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 整页（手机版）：54 高页头 + 38 圆钮。内嵌仍是三栏细栏头（24/14）。
    if (!embedded) {
      return SafeArea(
        bottom: false,
        child: MobileAppBar(
          title: project.name,
          actions: <Widget>[
            if (busy)
              _busyIndicator(mobile: true)
            else
              // 「新建」贴在「…」左侧：主操作在前，更多菜单保持最右。
              // 两枚并成一枚胶囊（整组一层玻璃），格与格之间只留 1dp 分隔线。
              // 图标统一成新建的「+」，两个 Tab 的差别只留在 tooltip——
              // 同一位置上的同一件事，换图形反而让人以为换了个功能。
              MobileTopBarButtonGroup(
                children: <Widget>[
                  MobileTopBarButton(
                    bare: true,
                    icon: Icons.add,
                    tooltip: tabIndex == 0 ? '新建会话' : '派一件事',
                    onPressed: onCreate,
                  ),
                  _menu(context, bare: true),
                ],
              ),
          ],
        ),
      );
    }

    return EmbeddedToolbar(
      title: project.name,
      // 不显示项目绝对路径：侧栏那一条已经是它的唯一标识，
      // 栏头再铺一串路径只会挤掉标题与右侧动作的位置。
      emphasizeTitle: true,
      showPaneToggles: true,
      // 内嵌时没有可返回的路由；模式也不挂在页头（同一屏里再摆一枚徽章
      // 等于把同一个身份说两遍）。
      actions: <Widget>[
        if (busy) _busyIndicator(mobile: false) else _menu(context),
      ],
    );
  }

  /// 「正在重命名 / 删除」的进度：占住与按钮等宽的位置，标题不会左右跳。
  Widget _busyIndicator({required bool mobile}) {
    return SizedBox(
      width: mobile ? kMobileTopBarButtonSize : 30,
      height: mobile ? kMobileTopBarButtonSize : 30,
      child: const Center(
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  /// 页头「…」：与右侧栏标签右键菜单同一套浮层（`AgentMenu`）——圆角、轻阴影、
  /// 主色悬停块。「删除项目」用分组线隔开，破坏性操作不该混在常规项里。
  ///
  /// [bare] 为真时触发器只留命中区：窄屏页头里它要和「新建」同处一枚胶囊，
  /// 背板由整组画一次。
  Widget _menu(BuildContext context, {bool bare = false}) {
    return AgentMenu<String>(
      width: AgentMenuStyle.panelMinWidth,
      // 与「…」的左边缘对齐后向右下展开（bottomStart）：锚在栏头右端，
      // 按 bottomEnd 会向左溢出、盖住标题与标签栏。
      alignment: AlignmentDirectional.bottomStart,
      alignmentOffset: const Offset(0, 4),
      // 触发器是自己带 onPressed 的按钮：点击交给它，组件只管开合状态。
      triggerHandlesTap: false,
      groups: const <AgentMenuGroup<String>>[
        AgentMenuGroup<String>(
          items: <AgentMenuItem<String>>[
            // 「关闭」排在最前：它是把这一栏收起来，最常用的退出口。
            AgentMenuItem<String>(
              value: 'close',
              label: '关闭',
              icon: Icons.close_rounded,
            ),
            AgentMenuItem<String>(
              value: 'rename',
              label: '重命名',
              icon: Icons.drive_file_rename_outline_rounded,
            ),
            AgentMenuItem<String>(
              value: 'copy',
              label: '复制路径',
              icon: Icons.content_copy_rounded,
            ),
            // 「删除项目」是破坏性操作，与前几项分开一组。
            AgentMenuItem<String>(
              value: 'delete',
              label: '删除项目',
              icon: Icons.delete_outline_rounded,
              dividerBefore: true,
            ),
          ],
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'close':
            onClose();
          case 'rename':
            onRename();
          case 'copy':
            copyProjectPath(context, project);
          default:
            onDelete();
        }
      },
      builder: (context, controller, open, hovering) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (!embedded) {
          return MobileTopBarButton(
            bare: bare,
            glyph: MobileTopBarGlyph.more,
            tooltip: '项目操作',
            onPressed: toggle,
          );
        }
        return IconButton(
          tooltip: '项目操作',
          onPressed: toggle,
          // 尺寸与栏头其它按钮一致：命中区 24、图标 14、8dp 圆角方形悬停底。
          style: _menuButtonStyle,
          iconSize: kPaneHeaderIconSize,
          icon: const Icon(Icons.more_horiz),
        );
      },
    );
  }

}
