import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/ui/adaptive_card_list.dart';
import '../../core/project_providers.dart';
import '../conversations/conversations_page.dart';
import '../shell/pane_surface.dart';
import '../shell/section_actions.dart';
import '../shell/selection_toolbar.dart';
import 'create_task_action.dart';
import 'task_detail_page.dart';

final tasksProvider = FutureProvider.family<List<TaskView>, String>((
  ref,
  projectId,
) async {
  final client = ref.watch(apiClientProvider);
  if (client == null) {
    return <TaskView>[];
  }
  final page = await client.getJson(
    '/api/tasks',
    query: <String, String>{
      'limit': '50',
      if (projectId.isNotEmpty) 'project_id': projectId,
    },
  );
  final items = page['items'] as List<dynamic>? ?? const <dynamic>[];
  return items
      .whereType<Map<String, dynamic>>()
      .map(TaskView.fromJson)
      .toList(growable: false);
});

/// 只有结束的任务可以删：执行中的任务删除后 worker 仍会上报，状态机会悬空。
bool canDeleteTask(String state) =>
    state == 'succeeded' || state == 'failed' || state == 'canceled';

/// 任务列表。这里只显示 L3（用户明确要办的事），问答不进列表。
///
/// 任务挂在项目下（归属经会话派生），列表按 `project_id` 过滤；
/// 模式决定了技能清单里有没有编码任务——普通项目连入口都不出现。
class TasksPage extends ConsumerStatefulWidget {
  const TasksPage({
    super.key,
    required this.projectId,
    this.mode = ProjectModes.work,
    this.projectPath,
    this.embedded = false,
    this.onOpenTask,
    this.actionsController,
    this.showCreateFab = true,
  });

  final String projectId;
  final String mode;
  final String? projectPath;

  /// 嵌在项目详情里时不要自己的 AppBar。
  final bool embedded;

  /// 是否画「派一件事」悬浮按钮。
  ///
  /// 宿主已经在页头放了同一动作时传 `false`：窄屏项目详情页头有一枚「新建」
  /// 圆钮，底部再浮一个按钮等于同一个操作出现两次，白占一条列表高度。
  /// 宽屏中栏的详情页头没有这枚入口，仍靠这个悬浮按钮派任务。
  final bool showCreateFab;

  /// 嵌在项目详情里时，把「管理 / 刷新」这组动作交给外层那一行渲染：
  /// 两个视图共用一条头部，工具行不再单独占一行。
  final SectionActionsController? actionsController;

  /// 宽屏外壳接管"打开任务"：右侧原地切换，不叠整页。
  ///
  /// 不传时退回 `Navigator.push`，窄屏与旧入口的行为完全不变。
  final ValueChanged<String>? onOpenTask;

  @override
  ConsumerState<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends ConsumerState<TasksPage> {
  /// 管理模式：列表项换成复选框，底部出现删除条。
  bool _managing = false;
  bool _deleting = false;
  final Set<String> _selected = <String>{};

  /// 列表里还有未结束的任务时，定时刷新，状态与"更新于 …"不能停在旧值。
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    // 页被回收时把动作带走：否则外层那一行可能还渲染着指向已销毁 State 的按钮。
    widget.actionsController?.reset();
    super.dispose();
  }

  /// 按列表里的状态决定要不要继续轮询。
  ///
  /// 用 `invalidate` 而不是自己 `setState`：`FutureProvider` 的刷新会保留上一份值，
  /// `when` 默认 `skipLoadingOnRefresh`，列表不会闪成转圈。
  void _syncPolling(List<TaskView> items) {
    final live = items.any((task) => !task.isTerminal);
    if (!live) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        ref.invalidate(tasksProvider(widget.projectId));
      }
    });
  }

  Future<void> _createTask() async {
    // 弹窗、编码任务表单与 POST 都在公共 action 里：详情页页头的「新建」
    // 圆钮走同一份实现，两边不会出现谁漏刷新。
    final taskId = await createTask(
      context,
      ref,
      projectId: widget.projectId,
      mode: widget.mode,
      projectPath: widget.projectPath,
      onOpenTask: widget.onOpenTask,
    );
    if (!mounted || taskId == null) {
      return;
    }
    ref.invalidate(tasksProvider(widget.projectId));
    ref.invalidate(projectProvider(widget.projectId));
  }

  void _enterManaging() {
    setState(() {
      _managing = true;
      _selected.clear();
    });
  }

  void _exitManaging() {
    if (_deleting) {
      return;
    }
    setState(() {
      _managing = false;
      _selected.clear();
    });
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) {
        _selected.add(id);
      }
    });
  }

  void _toggleAll() {
    // 从 provider 取最新列表：这组动作会被外层那一行缓存，闭包里的快照
    // 可能是上一次 build 的。
    final items =
        ref.read(tasksProvider(widget.projectId)).value ?? const <TaskView>[];
    final all = items
        .where((task) => canDeleteTask(task.state))
        .map((task) => task.id)
        .toSet();
    setState(() {
      if (all.isNotEmpty && _selected.length >= all.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(all);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList(growable: false);
    final client = ref.read(apiClientProvider);
    if (ids.isEmpty || _deleting || client == null) {
      return;
    }

    final confirmed = await confirmDeleteDialog(
      context,
      title: '删除 ${ids.length} 个任务？',
      message:
          '任务的步骤、审批与产物入口会一并删除，无法恢复。\n\n'
          '磁盘上的产物文件与编码任务工作树会保留在数据目录，供排障使用。',
      count: ids.length,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _deleting = true);
    final outcome = await deleteSelected(
      ids: ids,
      deleteOne: (id) => client.delete('/api/tasks/$id'),
    );
    if (!mounted) {
      return;
    }

    ref.invalidate(tasksProvider(widget.projectId));
    ref.invalidate(projectProvider(widget.projectId));
    setState(() {
      _deleting = false;
      _selected.removeWhere((id) => outcome.deleted.contains(id));
      if (!outcome.hasFailures) {
        _managing = false;
        _selected.clear();
      }
    });

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(deleteSummary('任务', outcome))));
  }

  /// 把右侧动作交给项目详情的合并行。
  ///
  /// 形状没变时只替换闭包：这发生在每次 build，不能顺手通知父页。
  /// 形状变了推到本帧结束后再通知，否则父页会在子页 build 期间被重建。
  void _reportActions(List<TaskView> items, int selectableCount) {
    final controller = widget.actionsController;
    if (controller == null) {
      return;
    }
    final next = SectionActions(
      managing: _managing,
      selectedCount: _selected.length,
      selectableCount: selectableCount,
      canManage: items.isNotEmpty,
      onManage: _enterManaging,
      onRefresh: () => ref.invalidate(tasksProvider(widget.projectId)),
      onToggleAll: _toggleAll,
      onDone: _exitManaging,
    );
    final current = controller.value;
    if (current != null && current.sameShape(next)) {
      controller.replace(next);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        controller.update(next);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksProvider(widget.projectId));
    final scheme = Theme.of(context).colorScheme;
    // 刷新期间状态是 loading，但上一份值仍在 `value` 里。用 `asData` 会让
    // 每 2 秒的轮询把操作行短暂清空（"管理"按钮闪一下），这里取上一份值。
    final items = tasks.value ?? const <TaskView>[];
    final selectable = items.where((task) => canDeleteTask(task.state)).length;

    // 有未结束的任务就继续轮询；全到终态后自动停表。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncPolling(items);
      }
    });

    final actions = <Widget>[
      if (_managing)
        SelectionAppBarActions(
          selectedCount: _selected.length,
          selectableCount: selectable,
          onToggleAll: _toggleAll,
          onDone: _exitManaging,
        )
      else ...<Widget>[
        if (items.isNotEmpty)
          TextButton(onPressed: _enterManaging, child: const Text('管理')),
        // 窄屏整页页头：38 玻璃圆钮（宽屏这组按钮由 `_SectionBar` 显示）。
        MobileTopBarButton(
          icon: Icons.refresh,
          tooltip: '刷新',
          onPressed: () => ref.invalidate(tasksProvider(widget.projectId)),
        ),
      ],
    ];

    // 嵌在详情页里时，这组按钮显示在外层合并行的右侧而不是这里。
    _reportActions(items, selectable);

    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：嵌在项目详情里时不能变回实色白底。
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded ? paneSurfaceColor(scheme) : null,
      appBar: widget.embedded
          ? null
          : MobileAppBar(
              leading: _managing
                  ? MobileTopBarButton(
                      icon: Icons.close,
                      tooltip: '退出管理',
                      onPressed: _deleting ? null : _exitManaging,
                    )
                  : null,
              title: _managing ? '已选 ${_selected.length} 项' : '任务',
              actions: actions,
            ),
      floatingActionButton: _managing || !widget.showCreateFab
          ? null
          : FloatingActionButton.extended(
              onPressed: _createTask,
              icon: const Icon(Icons.add_task),
              label: const Text('派一件事'),
            ),
      bottomNavigationBar: _managing
          ? SelectionDeleteBar(
              selectedCount: _selected.length,
              busy: _deleting,
              onDelete: _deleteSelected,
            )
          : null,
      body: Column(
        children: <Widget>[
          Expanded(
            child: tasks.when(
              // 轮询时偶发失败不该把整页换成错误卡：有上一份数据就继续显示。
              skipError: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      error is ApiException ? error.userMessage : '$error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () =>
                          ref.invalidate(tasksProvider(widget.projectId)),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.task_alt,
                            size: 40,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '还没有任务',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontSize: AppFontSize.lg),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '任务只由你明确发起；建议与问答留在对话里。',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontSize: AppFontSize.sm,
                                  color: AppPalette.of(context).text.secondary,
                                ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async =>
                      ref.invalidate(tasksProvider(widget.projectId)),
                  child: AdaptiveCardList(
                    // 内容不满一屏时也要能下拉刷新。
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      12 + MediaQuery.paddingOf(context).bottom,
                    ),
                    itemCount: items.length,
                    isSelected: (index) =>
                        _managing && _selected.contains(items[index].id),
                    itemBuilder: (context, index) {
                      final task = items[index];
                      return TaskListTile(
                        task: task,
                        managing: _managing,
                        selected: _selected.contains(task.id),
                        onToggle: () => _toggle(task.id),
                        onOpen: () async {
                          final open = widget.onOpenTask;
                          if (open != null) {
                            open(task.id);
                            return;
                          }
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => TaskDetailPage(taskId: task.id),
                            ),
                          );
                          ref.invalidate(tasksProvider(widget.projectId));
                          ref.invalidate(projectProvider(widget.projectId));
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 任务列表的一行。管理态显示复选框；未结束的任务不可勾选。
///
/// 独立成公开组件是为了能直接测「执行中的任务不能被选中」——这条规则
/// 服务端也会校验，客户端做在界面上只是少一次必然失败的请求。
class TaskListTile extends StatelessWidget {
  const TaskListTile({
    super.key,
    required this.task,
    required this.managing,
    required this.selected,
    required this.onToggle,
    required this.onOpen,
  });

  final TaskView task;
  final bool managing;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final deletable = canDeleteTask(task.state);

    // 内文与录音 / 会话共用 `AdaptiveCardRow`：图标块、字阶、内边距一处定义。
    return AdaptiveCardRow(
      icon: _stateIcon(task.state),
      iconColor: _stateColor(task.state, palette),
      title: task.skill ?? task.type,
      trailing: managing
          ? null
          : task.pendingApproval != null
          ? _Badge(text: '待确认', color: scheme.tertiary)
          : null,
      meta: managing && !deletable
          ? '${taskStateLabel(task.state)} · 先取消再删'
          : '${taskStateLabel(task.state)} · 更新于 ${formatTime(task.updatedAt)}',
      selected: managing && selected,
      // 复选框占 34 图标槽位：进出管理态内容不左右跳。
      leading: managing
          ? Checkbox(
              value: selected,
              onChanged: deletable ? (_) => onToggle() : null,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            )
          : null,
      onTap: managing ? (deletable ? onToggle : null) : onOpen,
    );
  }

  /// 任务状态图标：与原来的圆形状态点同一套字形，只是换成卡片图标块。
  IconData _stateIcon(String state) => switch (state) {
    'succeeded' => Icons.check,
    'failed' => Icons.close,
    'canceled' => Icons.block,
    'needs_approval' => Icons.pan_tool_outlined,
    'running' => Icons.play_arrow,
    _ => Icons.schedule,
  };

  /// 状态色统一取 `AppPalette.status`：卡片图标块与状态胶囊同一套色。
  Color _stateColor(String state, AppPalette palette) => switch (state) {
    'succeeded' => palette.status.success,
    'failed' => palette.status.danger,
    'canceled' => palette.status.neutral,
    'needs_approval' => palette.status.warning,
    'running' => palette.status.info,
    _ => palette.status.neutral,
  };
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: color, fontWeight: AppWeight.semiBold),
      ),
    );
  }
}
