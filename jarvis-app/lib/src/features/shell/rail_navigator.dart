import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import '../../core/ui/agent_menu.dart';
import '../conversations/conversations_page.dart';
import '../projects/project_actions.dart';
import 'new_conversation_action.dart';
import 'new_conversation_icon.dart';
import 'pane_controls.dart';
import 'rail_section_icons.dart';
import 'rail_view_menu.dart';
import 'shell_layout_state.dart';
import 'project_icon.dart';

/// 「项目」标题行里「新建项目」入口的 Key。
///
/// 文案与图标都可能改，测试靠它定位这一簇里的第三枚按钮。
const Key kRailAddProjectKey = Key('shell-rail-add-project');

/// 项目行行尾两枚按钮的 Key：带项目 id，测试才能区分是哪一行。
///
/// 两枚按钮只在悬停时可见，而且每行都用同一对 tooltip（「项目操作」「新会话」），
/// 按 tooltip 找会一次命中所有项目行。
Key railProjectActionsKey(String projectId) =>
    ValueKey<String>('shell-rail-project-actions-$projectId');

Key railProjectNewConversationKey(String projectId) =>
    ValueKey<String>('shell-rail-project-new-$projectId');

/// 「项目」标题行右端那一簇图标的尺寸。
///
/// 比行内图标（[kRailItemIconSize] = 16）小一档：它们是分组标题的附属动作，
/// 不该比项目名更抢眼。
const double kRailSectionIconSize = 15;

/// 宽屏侧栏的导航树：项目 → 会话。
///
/// 只有**展开**的项目才会去拉会话：`conversationsProvider` 是带缓存的 family，
/// 收起再展开只命中缓存，不会重复打服务端。默认展开第一个项目——
/// 新用户进来看不到任何条目时，最容易误解成"数据没同步过来"。
///
/// 任务不进侧栏：它只在项目详情的「任务」Tab 里看，侧栏保持一条会话主线。
///
/// 项目行在宽屏是**纯导航展开器**：单击只展开 / 收起它下面的会话列表，中栏
/// 不跟着换页（参考图里点文件夹就是把树展开，不是"打开这个目录"）。项目详情
/// 页改由行尾「项目操作」菜单里的「打开项目」进入。
class RailNavigator extends ConsumerStatefulWidget {
  const RailNavigator({
    super.key,
    required this.onCreateProject,
    required this.onOpenRecordings,
    required this.onOpenCanvas,
  });

  /// 分组标题右侧的「新建项目」。入口从宽屏的悬浮按钮挪到这里，
  /// 否则它会压在右侧内嵌页面的按钮上。
  final VoidCallback onCreateProject;

  /// 「录音笔记」入口。它与「新建会话」同属左栏顶部的动作区，
  /// 原先挂在底部，和设置挤在一起，两个都显得像"页脚设置项"。
  final VoidCallback onOpenRecordings;

  /// 「无限画布」入口。排在「录音笔记」下面：两者都是"进去做点东西"的工具页，
  /// 与上面那行「新会话」的"立刻开一条对话"分属两组语义。
  final VoidCallback onOpenCanvas;

  @override
  ConsumerState<RailNavigator> createState() => _RailNavigatorState();
}

class _RailNavigatorState extends ConsumerState<RailNavigator> {
  /// `null` 表示用户还没手动展开/收起过，此时默认展开第一个项目。
  ///
  /// 用 null 当哨兵而不是在 build 里 setState：后者会在首帧构建期间触发重建，
  /// 既违反 Flutter 的约束，也会把"用户主动收起全部"这个合法状态冲掉。
  Set<String>? _expanded;

  void _select(ShellTarget target) {
    ref.read(shellTargetProvider.notifier).select(target);
  }

  void _toggle(String projectId, Set<String> current) {
    setState(() {
      final next = Set<String>.of(current);
      if (!next.remove(projectId)) {
        next.add(projectId);
      }
      _expanded = next;
    });
  }

  /// 项目被删掉后的收尾：中栏若停在该项目名下就清空，展开集合里也把它摘掉。
  ///
  /// 顺序按 [ShellTargetController.forgetProject] 的要求：先导航再剪枝，
  /// 否则后退栈里会留一条指向已删项目的记录。
  void _forgetProject(Project project) {
    final current = ref.read(shellTargetProvider);
    if (current?.projectId == project.id) {
      final targets = ref.read(shellTargetProvider.notifier);
      targets.clear();
      targets.forgetProject(project.id);
    }
    final expanded = _expanded;
    if (expanded != null && expanded.contains(project.id)) {
      setState(() => _expanded = <String>{...expanded}..remove(project.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectsProvider);
    final target = ref.watch(shellTargetProvider);

    // 选中项可能来自别处（例如在项目详情里新建会话、或在会话里派任务）：
    // 它所属的项目若还收着，侧栏就看不到高亮，像是"点了没反应"。
    ref.listen(shellTargetProvider, (previous, next) {
      if (next == null) {
        return;
      }
      final items = ref.read(projectsProvider).value ?? const <Project>[];
      if (items.isEmpty ||
          !items.any((project) => project.id == next.projectId)) {
        return;
      }
      final current = _expanded ?? <String>{items.first.id};
      if (current.contains(next.projectId)) {
        return;
      }
      setState(() => _expanded = <String>{...current, next.projectId});
    });

    return projects.when(
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (error, _) => _RailError(
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(projectsProvider),
      ),
      data: (items) {
        final expanded =
            _expanded ?? <String>{if (items.isNotEmpty) items.first.id};
        // 新建会话要落到某个项目：优先当前选中的，其次列表第一个。
        final host = hostProjectFor(items, target);
        // 录音列表 / 详情 / 进行页同属一个入口：三种状态下这一行都算选中。
        final recordingsSelected = isRecordingPageTarget(target);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              // 左右留白交给每行自己（与导航行同一套 pill inset）：
              // 这样两行动作的悬停底和下面的会话行从同一条线起笔。
              // 顶部不再留白：这两行要紧贴栏头，多出来的 4dp 会让「新建会话」
              // 看起来悬在半空。
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Tooltip(
                    // 没有项目时照样能开会话：那是一条不挂项目的直聊。
                    message: host == null
                        ? '新开一条无项目的对话'
                        : '在「${host.name}」里新开一个会话',
                    child: _RailActionRow(
                      key: kRailNewConversationKey,
                      // 「新建会话」缩成「新会话」：与下面那行「录音笔记」字数对齐，
                      // 顶部动作区不再一行长一行短。
                      label: '新会话',
                      iconBuilder: (color) => NewConversationIcon(
                        size: kRailItemIconSize,
                        color: color,
                      ),
                      onTap: () => createConversation(context, ref, host: host),
                    ),
                  ),
                  // 与「新建会话」同一套行样式；行距来自行自己的上下留白，
                  // 与下面会话行之间 4dp 的节奏一致，不再额外垫一个 gap。
                  _RailActionRow(
                    key: kRailRecordingsKey,
                    label: '录音笔记',
                    selected: recordingsSelected,
                    iconBuilder: (color) => Icon(
                      Icons.mic_none_outlined,
                      size: kRailItemIconSize,
                      color: color,
                    ),
                    onTap: widget.onOpenRecordings,
                  ),
                  _RailActionRow(
                    key: kRailCanvasKey,
                    label: '无限画布',
                    selected: target is CanvasTarget,
                    // 节点图用「一张网」表达：与上面那枚麦克风、下面导航树里的
                    // 文件夹同属 16dp 的行内图标，不另开一套尺寸。
                    iconBuilder: (color) => Icon(
                      Icons.hub_outlined,
                      size: kRailItemIconSize,
                      color: color,
                    ),
                    onTap: widget.onOpenCanvas,
                  ),
                ],
              ),
            ),
            Expanded(
              // 「对话」分组与「项目」分组共用同一个滚动容器：分组标题跟着
              // 内容一起滚，而不是把导航树挤在一个更矮的窗口里。
              child: ListView(
                // 水平内边距交给行自己（见 `_RailRow`）：
                // 这里再垫一层就会和行内边距叠加，左边缘就比 12 大一档。
                padding: const EdgeInsets.fromLTRB(0, 2, 0, 12),
                children: <Widget>[
                  _UnassignedSection(target: target, onSelect: _select),
                  _SectionHeader(onCreate: widget.onCreateProject),
                  if (items.isEmpty)
                    const _RailEmpty()
                  else
                    for (final project in items)
                      _ProjectSection(
                        project: project,
                        expanded: expanded.contains(project.id),
                        target: target,
                        onToggle: () => _toggle(project.id, expanded),
                        onSelect: _select,
                        onDeleted: _forgetProject,
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

/// 左栏顶部的一行动作：图标 + 文案，整行可点。
///
/// 悬停底与导航行（`_RailRow`）完全同一套：8dp 的外边距把底色收在文字两侧，
/// 圆角 [AppRadius.sm]，`surfaceContainerHighest` 0.5，行高 32。
/// 两处如果各用各的灰，扫过侧栏时就会看到"浮起来"的两种深度，
/// 明明都在左栏里，却像两个层级的控件。
class _RailActionRow extends StatelessWidget {
  const _RailActionRow({
    super.key,
    required this.label,
    required this.iconBuilder,
    required this.onTap,
    this.selected = false,
  });

  final String label;

  /// 把当前该用的颜色交给调用方：不可点时图标要和文字一起淡掉。
  final Widget Function(Color color) iconBuilder;

  /// 为 `null` 时整行淡成禁用态（保留这个口子：以后可能还有"暂时不能点"的动作）。
  final VoidCallback? onTap;

  /// 这一行对应的页面正显示在中栏。与 `_RailRow` 同一套选中态：
  /// 只换 0.9 中性灰底，字重不变——动作行也是导航入口，不能只有悬停没有停留。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final interactive = onTap != null;
    final foreground = interactive
        ? palette.text.primary
        : palette.text.disabled;

    return Padding(
      // 与 `_RailRow` 同一套留白：悬停底画在这层留白**里面**，
      // 让它和下面会话行的底色从同一条竖线起笔。
      padding: const EdgeInsets.fromLTRB(
        kRailRowPillInset,
        2,
        kRailRowPillInset - kRailHandleWidth,
        2,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: interactive ? onTap : null,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          // 与导航行同为 0.9：悬停重、选中淡（两者按需求对调过，别改回去）。
          hoverColor: interactive
              ? scheme.surfaceContainerHighest.withValues(alpha: 0.9)
              : Colors.transparent,
          child: Container(
            // 与会话行同高：这两行在视觉上属于同一列动作。
            height: 32,
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                  : null,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              children: <Widget>[
                iconBuilder(foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppFontSize.base,
                      height: AppLineHeight.tight,
                      // 与「项目 / 会话」行同字重：选中态只由底色表达。
                      fontWeight: AppWeight.regular,
                      color: foreground,
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

/// 「项目」分组标题 + 右侧三枚图标：搜索、视图选项、新建项目。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      // 贴分隔线那一侧扣掉 8dp 栏缝，视觉左右都是同一个内边距。
      padding: const EdgeInsets.fromLTRB(
        kPaneContentInset,
        12,
        kPaneEdgeInset,
        4,
      ),
      child: Row(
        children: <Widget>[
          Text(
            '项目',
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: AppFontSize.base,
              // 分组标题不加粗：与下面各行文字同字重，层级交给字号缩进与颜色。
              fontWeight: AppWeight.regular,
              letterSpacing: AppLetterSpacing.tight,
              color: AppPalette.of(context).text.secondary,
            ),
          ),
          const Spacer(),
          // 搜索、视图选项、新建项目：三枚彼此只隔 2dp，属于同一个
          // 「这一行有什么」的动作组。搜索原先在模式胶囊那一行，模式下拉
          // 上移进栏头后，这一行才是它该待的地方（搜索的就是这组项目）。
          const RailSearchButton(size: kRailSectionIconSize),
          const SizedBox(width: 2),
          const RailViewOptionsButton(iconSize: kRailSectionIconSize),
          const SizedBox(width: 2),
          RailSectionIconButton(
            key: kRailAddProjectKey,
            iconSize: kRailSectionIconSize,
            // 参考图里这一枚是「右上角敞开的文件夹 + 缺口处一枚加号」。
            iconBuilder: (color) => RailSectionGlyph(
              kind: RailSectionGlyphKind.addProject,
              color: color,
              size: kRailSectionIconSize,
            ),
            tooltip: '新建项目',
            onPressed: onCreate,
          ),
        ],
      ),
    );
  }
}

/// 「对话」分组：不挂项目的直聊。
///
/// 排在「项目」之前、两种模式都显示——这批会话本来就不属于任何项目，
/// 也就没有"当前模式"可言。列表为空时整组不渲染：空态本身由中栏的
/// 「聊天」页承担，侧栏不必再来一句"还没有对话"。
class _UnassignedSection extends ConsumerWidget {
  const _UnassignedSection({required this.target, required this.onSelect});

  final ShellTarget? target;
  final void Function(ShellTarget target) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(unassignedConversationsProvider);
    final items = conversations.asData?.value ?? const <ConversationSummary>[];
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    // 用局部变量接一下，模式匹配才能提升类型（对字段访问不做类型提升）。
    final current = target;
    final selectedId =
        current is ConversationTarget && current.projectId.isEmpty
        ? current.conversationId
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _RailGroupTitle(label: '对话'),
        for (final conversation in items)
          _RailRow(
            indent: true,
            label: conversation.title,
            trailingText: formatRailTime(conversation.updatedAt),
            selected: selectedId == conversation.id,
            onTap: () => onSelect(
              ConversationTarget(
                // 空串 = 无归属：与会话页的栏头标题、后退落点同一套口径。
                projectId: '',
                conversationId: conversation.id,
                title: conversation.title,
              ),
            ),
          ),
      ],
    );
  }
}

/// 分组标题（「对话」）。与「项目」标题同一套字与边距，只是不带动作按钮：
/// 搜索、视图选项、新建项目说的都是项目，跟这批直聊无关。
class _RailGroupTitle extends StatelessWidget {
  const _RailGroupTitle({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPaneContentInset,
        12,
        kPaneEdgeInset,
        4,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: AppFontSize.base,
          // 与「项目」标题同一套：不吃字重，只靠颜色下沉一档。
          fontWeight: AppWeight.regular,
          letterSpacing: AppLetterSpacing.tight,
          color: AppPalette.of(context).text.secondary,
        ),
      ),
    );
  }
}

/// 一个项目：一行标题 + 展开后的会话列表。
///
/// 这一行不再代表"打开项目详情"：单击只切展开，行尾两枚按钮才是对这个项目
/// 做事。图标与行底因此分两套判定：中栏显示它的会话 / 任务 / 详情页时图标都
/// 转成项目强调色（"当前所在的项目"），但行底色只在项目详情页时才出现——
/// 会话进行中已经有一行选中底，项目行再叠一层就成了两个并列的焦点。
class _ProjectSection extends ConsumerStatefulWidget {
  const _ProjectSection({
    required this.project,
    required this.expanded,
    required this.target,
    required this.onToggle,
    required this.onSelect,
    required this.onDeleted,
  });

  final Project project;
  final bool expanded;
  final ShellTarget? target;
  final VoidCallback onToggle;
  final void Function(ShellTarget target) onSelect;

  /// 删除成功后的收尾（清中栏、从外层的展开集合里摘掉）。
  final ValueChanged<Project> onDeleted;

  @override
  ConsumerState<_ProjectSection> createState() => _ProjectSectionState();
}

class _ProjectSectionState extends ConsumerState<_ProjectSection> {
  /// 行悬停：行尾两枚按钮只在悬停时浮出来。
  ///
  /// 状态放在这一层而不是 `_RailRow`：同一次悬停要同时驱动两枚按钮的显隐，
  /// 而 `_RailRow` 是会话行也复用的通用行，不该为项目行加一份私有状态。
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final target = widget.target;
    // 用局部变量接一下再比：`target?.projectId` 为空时不该落进任何项目。
    //
    // 这里刻意拆成两个判定：
    // - 图标：中栏在看这个项目名下的任何页面（会话 / 任务 / 详情）都算"当前项目"，
    //   蓝色文件夹负责指路；
    // - 行底色：只在**中栏就是项目详情页**时才画。会话进行中时会话行已经有一层
    //   选中底，项目行再叠一层就变成两条并列的"当前"，扫过去分不清哪个是焦点。
    final inProject = target?.projectId == project.id;
    final selected = target is ProjectTarget && target.projectId == project.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _RailRow(
          // 参考图里的三态文件夹：收起 / 展开 / 选中（选中换项目强调色，不换形状）。
          // 展开态不再另画一枚箭头：整行点击就是开关，图标自己说得清。
          icon: ProjectFolderIcon(
            size: kRailItemIconSize,
            expanded: widget.expanded,
            selected: inProject,
          ),
          label: project.name,
          selected: selected,
          onTap: widget.onToggle,
          onHoverChanged: (value) {
            if (value != _hovering) {
              setState(() => _hovering = value);
            }
          },
          trailing: _ProjectRowActions(
            project: project,
            hovered: _hovering,
            onDeleted: widget.onDeleted,
          ),
        ),
        // 只有展开时才挂载：收起状态下不 watch，等于不发请求。
        if (widget.expanded)
          _ProjectChildren(
            project: project,
            target: widget.target,
            onSelect: widget.onSelect,
          ),
      ],
    );
  }
}

/// 项目行行尾的两枚动作：项目操作（浮层菜单）与新会话。
///
/// 只在悬停时可见，但**位置常驻**（透明度切换而不是条件挂载）：
/// - 条件挂载会让标题在悬停的一瞬间被挤窄，来回扫过整栏时文字一直在抖；
/// - 菜单开着时鼠标已经移出这一行，按钮若跟着消失，锚点看起来像被删掉了。
class _ProjectRowActions extends ConsumerStatefulWidget {
  const _ProjectRowActions({
    required this.project,
    required this.hovered,
    required this.onDeleted,
  });

  final Project project;

  /// 所在行是否被悬停。菜单打开时即使它为 false，按钮也必须留着（见类注释）。
  final bool hovered;

  final ValueChanged<Project> onDeleted;

  @override
  ConsumerState<_ProjectRowActions> createState() => _ProjectRowActionsState();
}

class _ProjectRowActionsState extends ConsumerState<_ProjectRowActions> {
  /// 菜单是否展开。
  ///
  /// `AgentMenu` 只在 `builder` 里下发 `open`，而它内部的 `MenuController`
  /// 不通知重建（见 `agent_menu.dart` 的说明），所以这里把下发的值推迟到帧末
  /// 落进 State：build 期间直接 setState 会触发"构建中重建"的断言。
  bool _menuOpen = false;

  bool get _visible => widget.hovered || _menuOpen;

  void _syncMenuOpen(bool open) {
    if (open == _menuOpen) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _menuOpen != open) {
        setState(() => _menuOpen = open);
      }
    });
  }

  void _openProject() {
    ref
        .read(shellTargetProvider.notifier)
        .select(ProjectTarget(widget.project));
  }

  Future<void> _rename() async {
    await renameProject(context, ref, widget.project);
  }

  Future<void> _copyPath() => copyProjectPath(context, widget.project);

  Future<void> _delete() async {
    final project = widget.project;
    final confirmed = await confirmDeleteProject(context, project);
    if (!confirmed || !mounted) {
      return;
    }
    final deleted = await deleteProject(context, ref, project);
    if (!deleted || !mounted) {
      return;
    }
    widget.onDeleted(project);
  }

  Future<void> _newConversation() async {
    // 建完会自动选中新会话，外层 `ref.listen` 顺带把本项目展开。
    await createConversation(context, ref, host: widget.project);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      // 120ms：与侧栏其它浮出的动作同节奏，扫过整栏时不会一串一串地闪。
      duration: const Duration(milliseconds: 120),
      child: IgnorePointer(
        ignoring: !_visible,
        child: ExcludeFocus(
          excluding: !_visible,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AgentMenu<String>(
                width: AgentMenuStyle.panelMinWidth,
                // 右对齐锚点：项目行贴着侧栏右沿，按 `bottomStart` 展开会压到
                // 中栏内容上；`bottomEnd` + 右对齐偏移让面板向左盖在侧栏里。
                alignment: AlignmentDirectional.bottomEnd,
                alignmentOffset: AgentMenuStyle.rightAlignedOffset(
                  AgentMenuStyle.panelMinWidth,
                ),
                // 触发器是自己带 onPressed 的按钮：点击交给它，组件只管开合。
                triggerHandlesTap: false,
                groups: const <AgentMenuGroup<String>>[
                  AgentMenuGroup<String>(
                    items: <AgentMenuItem<String>>[
                      AgentMenuItem<String>(
                        value: 'open',
                        label: '打开项目',
                        icon: Icons.open_in_new_rounded,
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
                      // 破坏性操作与前几项分开一组。
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
                    case 'open':
                      _openProject();
                    case 'rename':
                      _rename();
                    case 'copy':
                      _copyPath();
                    default:
                      _delete();
                  }
                },
                builder: (context, controller, open, hovering) {
                  // 帧末同步开合态：开着菜单时按钮要继续留在原地。
                  _syncMenuOpen(open);
                  return RailSectionIconButton(
                    key: railProjectActionsKey(widget.project.id),
                    icon: Icons.more_horiz,
                    tooltip: '项目操作',
                    active: open,
                    onPressed: () =>
                        controller.isOpen ? controller.close() : controller.open(),
                  );
                },
              ),
              const SizedBox(width: 2),
              RailSectionIconButton(
                key: railProjectNewConversationKey(widget.project.id),
                // 与侧栏顶部「新会话」同一枚自绘图标：同一个动作不摆两种图形。
                iconBuilder: (color) => NewConversationIcon(
                  size: kRailItemIconSize,
                  color: color,
                ),
                tooltip: '新会话',
                onPressed: _newConversation,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectChildren extends ConsumerWidget {
  const _ProjectChildren({
    required this.project,
    required this.target,
    required this.onSelect,
  });

  final Project project;
  final ShellTarget? target;
  final void Function(ShellTarget target) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationsProvider(project.id));

    final conversationItems =
        conversations.asData?.value ?? const <ConversationSummary>[];

    if (conversations.isLoading && conversationItems.isEmpty) {
      return const _RailHint('载入中…');
    }
    if (conversations.hasError && conversationItems.isEmpty) {
      return _RailHint(
        '载入失败，点这里重试',
        onTap: () => ref.invalidate(conversationsProvider(project.id)),
      );
    }
    if (conversationItems.isEmpty) {
      return const _RailHint('还没有会话');
    }

    // 用局部变量接一下，模式匹配才能提升类型（对字段访问不做类型提升）。
    final current = target;
    final selectedConversation =
        current is ConversationTarget && current.projectId == project.id
        ? current.conversationId
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final conversation in conversationItems)
          _RailRow(
            indent: true,
            label: conversation.title,
            trailingText: formatRailTime(conversation.updatedAt),
            selected: selectedConversation == conversation.id,
            onTap: () => onSelect(
              ConversationTarget(
                projectId: project.id,
                conversationId: conversation.id,
                title: conversation.title,
                projectPath: project.path,
                project: project,
              ),
            ),
          ),
      ],
    );
  }
}

/// 侧栏里的一行：项目行与会话行共用，只有缩进与行高不同。
///
/// 选中与悬停都是中性浅灰圆角块，没有左侧强调色竖条：模式色已经由顶部胶囊
/// 表达，列表里再来一条色带只会让整栏更花（参考图也是这个取向）。
class _RailRow extends StatelessWidget {
  const _RailRow({
    this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailingText,
    this.trailing,
    this.onHoverChanged,
    this.indent = false,
  });

  /// 行首图标。项目行给的是自绘的三态文件夹；会话行不挂图标（参考图里没有），
  /// 标题直接与项目标题左对齐。
  final Widget? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? trailingText;
  final Widget? trailing;

  /// 悬停态上报给调用方：项目行的行尾按钮要跟着显隐。
  ///
  /// 交给调用方持有而不是存在这一层：同一次悬停要同时驱动两枚按钮，
  /// 而会话行根本不关心悬停。
  final ValueChanged<bool>? onHoverChanged;

  /// 会话行：整体缩进一档，行高更矮。字号与项目行同档（`base`），
  /// 层级靠缩进与行高区分；字重不参与分层（统一 w400，选中只换底色）。
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);

    return Padding(
      // 悬停底与选中底都画在这层留白**里面**（InkWell / Container 自己的矩形）。
      // 留白垫在内层只会把文字推进去，底还是从窗口左边缘一路铺到分隔线。
      padding: const EdgeInsets.fromLTRB(
        kRailRowPillInset,
        2,
        kRailRowPillInset - kRailHandleWidth,
        2,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onHover: onHoverChanged,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          // 悬停重、选中淡：与常规相反，两者按需求对调过，别当笔误改回去。
          hoverColor: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          child: Container(
            // 行高定死而不是靠内边距凑：项目行与子项行的密度差是最明显的分层信号，
            // 交给 padding 算会被字号的行高带偏。
            height: indent ? 32 : 34,
            // 文字仍落在 12 的内容内边距上：8（块留白）+ 4（行内）= 12；
            // 右侧 4 再叠上栏缝的 8dp，视觉距离同样是 12。
            // 会话行没有图标，缩进给到「项目标题的起点」：8 + 28 = 36
            // （12 内容内边距 + 16 图标 + 8 图标与文字的间距）。
            padding: EdgeInsets.fromLTRB(indent ? 28 : 4, 0, 4, 0),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                  : null,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              children: <Widget>[
                if (icon != null) ...<Widget>[icon!, const SizedBox(width: 8)],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: AppFontSize.base,
                      height: AppLineHeight.tight,
                      // 与正文同字重：选中只换底色，不加粗。
                      // 字重一加，同一列的会话名就会比回答正文"重"一档，
                      // 侧栏读起来像标题列表而不是内容索引。
                      fontWeight: AppWeight.regular,
                      color: palette.text.primary,
                    ),
                  ),
                ),
                if (trailingText != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      trailingText!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: AppFontSize.xs,
                        height: AppLineHeight.tight,
                        color: palette.text.tertiary,
                      ),
                    ),
                  ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailHint extends StatelessWidget {
  const _RailHint(this.text, {this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        // 与会话标题左对齐（会话行的左内边距是 36）。
        padding: const EdgeInsets.fromLTRB(36, 4, kPaneEdgeInset, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: AppFontSize.sm,
            color: AppPalette.of(context).text.tertiary,
          ),
        ),
      ),
    );
  }
}

class _RailEmpty extends StatelessWidget {
  const _RailEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPaneContentInset,
        10,
        kPaneEdgeInset,
        10,
      ),
      child: Text(
        '还没有项目。\n建好之后，会话会在这里按项目分组。',
        style: theme.textTheme.labelSmall?.copyWith(
          color: AppPalette.of(context).text.secondary,
          height: AppLineHeight.relaxed,
        ),
      ),
    );
  }
}

class _RailError extends StatelessWidget {
  const _RailError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPaneContentInset,
        12,
        kPaneEdgeInset,
        12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
              height: AppLineHeight.normal,
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 侧栏会话行的时间戳：`刚刚 / 5分钟 / 9小时 / 1天 / 1个月 / 1年`。
///
/// 不复用 `formatTime`（`conversations_page.dart`）：那个函数服务的是
/// 「更新于 …」这类可读句子，要保住日期原样；侧栏这一列只有 10.5px 宽，
/// 一列时间忽长忽短会把会话标题挤成不同长度，所以这里刻意去掉「前」、
/// 去掉数字与单位之间的空格，只留「几个单位」。
///
/// 各档向下取整：满 24 小时进「天」，满 30 天进「个月」，满 365 天进「年」。
/// 时间戳缺失（<=0）给「—」而不是空串——`_RailRow` 只判 null，空串会留白。
String formatRailTime(int milliseconds, {DateTime? now}) {
  if (milliseconds <= 0) {
    return '—';
  }
  final delta = (now ?? DateTime.now()).difference(
    DateTime.fromMillisecondsSinceEpoch(milliseconds),
  );
  // 未来时间（本机时钟偏差）按「刚刚」算，不能让文案出现负数。
  if (delta.isNegative || delta.inMinutes < 1) {
    return '刚刚';
  }
  if (delta.inHours < 1) {
    return '${delta.inMinutes}分钟';
  }
  if (delta.inDays < 1) {
    return '${delta.inHours}小时';
  }
  if (delta.inDays < 30) {
    return '${delta.inDays}天';
  }
  if (delta.inDays < 365) {
    return '${delta.inDays ~/ 30}个月';
  }
  return '${delta.inDays ~/ 365}年';
}
