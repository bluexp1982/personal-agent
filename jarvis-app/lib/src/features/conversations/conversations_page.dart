import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/ui/adaptive_card_list.dart';
import '../../core/ui/conversation_icon.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/project_providers.dart';
import '../shell/pane_surface.dart';
import '../shell/section_actions.dart';
import '../shell/selection_toolbar.dart';
import 'chat_page.dart';

final conversationsProvider =
    FutureProvider.family<List<ConversationSummary>, String>((
      ref,
      projectId,
    ) async {
      final client = ref.watch(apiClientProvider);
      if (client == null) {
        return <ConversationSummary>[];
      }
      final page = await client.getJson(
        '/api/conversations',
        query: <String, String>{
          'limit': '50',
          if (projectId.isNotEmpty) 'project_id': projectId,
        },
      );
      final items = page['items'] as List<dynamic>? ?? const <dynamic>[];
      return items
          .whereType<Map<String, dynamic>>()
          .map(ConversationSummary.fromJson)
          .toList(growable: false);
    });

//// 无归属直聊：不挂项目的会话（侧栏「对话」分组，宽屏中栏的空态也建这种）。
///
/// 单独一个 provider 而不是复用 `conversationsProvider('')`：后者省略
/// `project_id` 参数等于"不筛选"，会把这批会话和项目下的会话混在一起。
final unassignedConversationsProvider = FutureProvider<List<ConversationSummary>>(
  (ref) async {
    final client = ref.watch(apiClientProvider);
    if (client == null) {
      return <ConversationSummary>[];
    }
    final page = await client.getJson(
      '/api/conversations',
      query: <String, String>{'unassigned': 'true', 'limit': '50'},
    );
    final items = page['items'] as List<dynamic>? ?? const <dynamic>[];
    return items
        .whereType<Map<String, dynamic>>()
        .map(ConversationSummary.fromJson)
        .toList(growable: false);
  },
);

/// 会话列表。L1/L2 的问答都落在这里，任务从会话里派生但不占据列表。
///
/// 会话挂在项目下：列表按 `project_id` 过滤，新建时带上归属。
class ConversationsPage extends ConsumerStatefulWidget {
  const ConversationsPage({
    super.key,
    required this.projectId,
    this.mode = ProjectModes.work,
    this.projectPath,
    this.embedded = false,
    this.onOpenConversation,
    this.actionsController,
  });

  final String projectId;
  final String mode;

  /// 项目目录，只用于编码任务对话框里"改的是哪儿"的只读展示。
  final String? projectPath;

  /// 嵌在项目详情里时不要自己的 AppBar（外层已经有头图与 Tab）。
  final bool embedded;

  /// 嵌在项目详情里时，把「管理 / 刷新」这组动作交给外层那一行渲染：
  /// 两个视图共用一条头部，工具行不再单独占一行。
  final SectionActionsController? actionsController;

  /// 宽屏外壳接管"打开会话"：右侧原地切换，不叠整页。
  ///
  /// 不传时退回 `Navigator.push`，窄屏与旧入口的行为完全不变。
  final ValueChanged<ConversationSummary>? onOpenConversation;

  @override
  ConsumerState<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends ConsumerState<ConversationsPage> {
  /// 管理模式：列表项换成复选框，底部出现删除条。
  bool _managing = false;
  bool _deleting = false;
  final Set<String> _selected = <String>{};

  @override
  void dispose() {
    // 页被回收时把动作带走：否则外层那一行可能还渲染着指向已销毁 State 的按钮。
    widget.actionsController?.reset();
    super.dispose();
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
        ref.read(conversationsProvider(widget.projectId)).asData?.value ??
        const <ConversationSummary>[];
    final all = items.map((item) => item.id).toSet();
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
      title: '删除 ${ids.length} 个会话？',
      message:
          '会话里的消息会一并删除，无法恢复。\n\n'
          '会话下的任务也会一起删除；如果还有未结束的任务，删除会失败——请先取消它。',
      count: ids.length,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _deleting = true);
    final outcome = await deleteSelected(
      ids: ids,
      deleteOne: (id) => client.delete('/api/conversations/$id'),
    );
    if (!mounted) {
      return;
    }

    ref.invalidate(conversationsProvider(widget.projectId));
    ref.invalidate(projectProvider(widget.projectId));
    setState(() {
      _deleting = false;
      // 失败项留在列表里，保持勾选，方便用户看清哪几条没删掉。
      _selected.removeWhere((id) => outcome.deleted.contains(id));
      if (!outcome.hasFailures) {
        _managing = false;
        _selected.clear();
      }
    });

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(deleteSummary('会话', outcome))));
  }

  /// 把右侧动作交给项目详情的合并行。
  ///
  /// 形状没变时只替换闭包：这发生在每次 build，不能顺手通知父页。
  /// 形状变了推到本帧结束后再通知，否则父页会在子页 build 期间被重建。
  void _reportActions(List<ConversationSummary> items) {
    final controller = widget.actionsController;
    if (controller == null) {
      return;
    }
    final next = SectionActions(
      managing: _managing,
      selectedCount: _selected.length,
      selectableCount: items.length,
      canManage: items.isNotEmpty,
      onManage: _enterManaging,
      onRefresh: () =>
          ref.invalidate(conversationsProvider(widget.projectId)),
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
    final conversations = ref.watch(conversationsProvider(widget.projectId));
    final scheme = Theme.of(context).colorScheme;
    // AppBar 需要提前知道条目数（决定是否显示「管理」、全选是否已满）。
    final items = conversations.asData?.value ?? const <ConversationSummary>[];

    final actions = <Widget>[
      if (_managing)
        SelectionAppBarActions(
          selectedCount: _selected.length,
          selectableCount: items.length,
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
          onPressed: () =>
              ref.invalidate(conversationsProvider(widget.projectId)),
        ),
      ],
    ];

    // 嵌在详情页里时，这组按钮显示在外层合并行的右侧而不是这里。
    _reportActions(items);

    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：嵌在项目详情里时不能让这一块变回实色白底，
      // 否则 Tab 切过去会看到中栏底色跳一下。
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded ? paneSurfaceColor(scheme) : null,
      // 嵌在项目详情里时不画第二层 AppBar：外层已有头图与 Tab。
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
              title: _managing ? '已选 ${_selected.length} 项' : '对话',
              actions: actions,
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
            child: conversations.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ErrorPanel(
                message: error is ApiException ? error.userMessage : '$error',
                onRetry: () =>
                    ref.invalidate(conversationsProvider(widget.projectId)),
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
                            Icons.forum_outlined,
                            size: 40,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '还没有对话',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontSize: AppFontSize.lg),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '问一句，先拿到判断；要办的事再单独派成任务。',
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

                return AdaptiveCardList(
                  // 底部再让开系统手势条，否则最后一条会被压住。
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
                    final item = items[index];
                    final selected = _selected.contains(item.id);

                    return AdaptiveCardRow(
                      icon: conversationIcon,
                      iconColor: scheme.primary,
                      title: item.title,
                      meta: '更新于 ${formatTime(item.updatedAt)}',
                      // 选中底由 AdaptiveCard 统一给，这里只负责标题变主色。
                      selected: _managing && selected,
                      // 复选框占 34 图标槽位：进出管理态内容不左右跳。
                      leading: _managing
                          ? Checkbox(
                              value: selected,
                              onChanged: (_) => _toggle(item.id),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            )
                          : null,
                      onTap: _managing
                          ? () => _toggle(item.id)
                          : () async {
                              final open = widget.onOpenConversation;
                              if (open != null) {
                                open(item);
                                return;
                              }
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ChatPage(
                                    conversationId: item.id,
                                    title: item.title,
                                    projectPath: widget.projectPath,
                                    projectId: item.projectId,
                                    // 归属项目才有"保存到项目"这条路：
                                    // 未归属会话的产物只能存到本机。
                                    canSaveMediaToProject:
                                        item.projectId.isNotEmpty,
                                    // 标题在详情页里被改（手动或自动生成）就
                                    // 立刻换掉本页缓存，不等返回。
                                    onRenamed: (_) {
                                      if (!mounted) {
                                        return;
                                      }
                                      ref.invalidate(
                                        conversationsProvider(
                                          widget.projectId,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              );
                              ref.invalidate(
                                conversationsProvider(widget.projectId),
                              );
                            },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.cloud_off_outlined,
            size: 36,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 简单的时间呈现：只区分"刚刚 / 分钟 / 小时 / 日期"，不引日期库。
///
/// 落到日期这一档时只给日期、不再带时分：这一档的语义是"哪天"，精确到
/// 分钟反而占了列表行宽度却没提供有用信息。
String formatTime(int milliseconds) {
  if (milliseconds <= 0) {
    return '未知时间';
  }
  final delta = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(milliseconds),
  );
  if (delta.inMinutes < 1) {
    return '刚刚';
  }
  if (delta.inHours < 1) {
    return '${delta.inMinutes} 分钟前';
  }
  if (delta.inDays < 1) {
    return '${delta.inHours} 小时前';
  }
  final at = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${at.month} 月 ${at.day} 日';
}
