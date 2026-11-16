import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/artifact_exporter.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/ui/shell_icon_button.dart';
import '../conversations/conversations_page.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/pane_surface.dart';
import '../shell/shell_layout_state.dart';
import 'approval_card.dart';

/// 任务详情：计划、审批、产物、失败原因与可执行动作。
///
/// 轮询间隔 1.5 秒，任务进入终态后停止；审批卡片是这一页的核心——
/// 执行型产品最不能出现的是"任务停在 needs_approval 但界面没有任何入口"。
class TaskDetailPage extends ConsumerStatefulWidget {
  const TaskDetailPage({
    super.key,
    required this.taskId,
    this.embedded = false,
  });

  final String taskId;

  /// 嵌在宽屏右侧栏里时不画自己的 AppBar，刷新入口挪进细工具行。
  final bool embedded;

  @override
  ConsumerState<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends ConsumerState<TaskDetailPage> {
  /// 栏头图标按钮的统一样式：命中区 24、8dp 圆角方形、零内边距。
  ///
  /// 与左栏栏头、中栏栏头（`pane_controls.dart`）和右栏标签栏用的是同一份
  /// 规格——只换形状不收尺寸的话，这一枚会比同一行里的其它按钮大一圈。
  static final ButtonStyle _headerButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  TaskView? _task;
  String? _error;
  bool _busy = false;
  Timer? _timer;

  /// 上一次渲染的内容指纹。轮询每 1.5 秒一次，但过程摘要 5 秒才变一次：
  /// 内容没变还重建，会打断文本选择与滚动。
  String? _fingerprint;
  DateTime? _lastRebuildAt;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => unawaited(_refresh(silent: true)),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    try {
      final json = await client.getJson('/api/tasks/${widget.taskId}');
      final task = TaskView.fromJson(json);
      if (!mounted) {
        return;
      }

      // 终态先停表：即便这次内容指纹没变，也不该再轮询下去。
      if (task.isTerminal) {
        _timer?.cancel();
      }

      final fingerprint = _fingerprintOf(task);
      final changed = fingerprint != _fingerprint || _error != null;
      // 仍在执行的步骤里，"多久没有新输出"是跟墙体时钟比出来的：内容完全
      // 不变时也要每隔几秒重建一次，否则这句话永远不会出现。
      final heartbeat =
          !task.isTerminal &&
          (_lastRebuildAt == null ||
              DateTime.now().difference(_lastRebuildAt!) >=
                  const Duration(seconds: 5));
      if (!changed && !heartbeat) {
        return;
      }

      _fingerprint = fingerprint;
      _lastRebuildAt = DateTime.now();
      setState(() {
        _task = task;
        _error = null;
      });
    } on ApiException catch (error) {
      if (!mounted || silent) {
        return;
      }
      setState(() => _error = error.userMessage);
    }
  }

  /// 与展示相关的字段指纹：任一变化都要重建，其余轮询直接跳过。
  ///
  /// 用哈希而不是逐字段比较：步骤过程摘要可能有多行，比较字符串本身
  /// 不比拼指纹便宜，而指纹只在这一页内部用。
  String _fingerprintOf(TaskView task) {
    final buffer = StringBuffer()
      ..write(task.state)
      ..write('|')
      ..write(task.updatedAt)
      ..write('|')
      ..write(task.finishedAt)
      ..write('|')
      ..write(task.pendingApproval?.id)
      ..write('|')
      ..write(task.retryCount)
      ..write('|')
      ..write(task.errorCode)
      ..write('|')
      ..write(task.worktree?.exists);
    for (final artifact in task.artifacts) {
      buffer.write('|a:${artifact.id}:${artifact.kind}:${artifact.size}');
    }
    for (final step in task.plan) {
      buffer.write(
        '|s:${step.seq}:${step.state}:${step.updatedAt}:'
        '${step.output?.hashCode}',
      );
    }
    return buffer.toString();
  }

  Future<void> _decide(
    String decision, {
    bool remember = false,
    String? rememberScope,
  }) async {
    final approval = _task?.pendingApproval;
    if (approval == null || _busy) {
      return;
    }
    await _action(() async {
      await ref.read(apiClientProvider)!.postJson(
        '/api/tasks/${widget.taskId}/approve',
        <String, Object>{
          'approval_id': approval.id,
          'decision': decision,
          // 老服务端忽略这个字段；新服务端据此在本任务内记住该类规则。
          'remember': remember,
          if (remember && rememberScope != null) 'remember_scope': rememberScope,
        },
      );
    }, decision == 'approve' ? '已批准' : '已拒绝');
  }

  Future<void> _cancel() => _action(
    () async => ref
        .read(apiClientProvider)!
        .postJson('/api/tasks/${widget.taskId}/cancel', null),
    // 服务端改完状态就返回，执行侧的停止是随后发生的：文案不能说成"已停止"。
    '已请求取消，正在停止执行',
  );

  /// 清理编码任务的现场（隔离工作树）。
  ///
  /// 只删服务端数据目录里的这棵克隆；原仓库里已合并的分支不受影响——
  /// 这一点必须在确认框里说清楚，否则没人敢点。
  Future<void> _cleanWorktree() async {
    final worktree = _task?.worktree;
    if (worktree == null || _busy) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理这个任务的现场？'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            '将删除服务端数据目录里的隔离工作树：\n${worktree.path}\n\n'
            '只删这棵克隆；已经合并回仓库的 ${worktree.branch} 分支不受影响。\n'
            '清理之后就无法再从现场查看或手动合并这次的改动了。',
            style: const TextStyle(height: AppLineHeight.normal),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    await _action(
      () async => ref
          .read(apiClientProvider)!
          .delete('/api/tasks/${widget.taskId}/worktree'),
      '现场已清理',
    );
  }

  Future<void> _retry() => _action(
    () async => ref
        .read(apiClientProvider)!
        .postJson('/api/tasks/${widget.taskId}/retry', null),
    '已重新排队',
  );

  Future<void> _action(
    Future<void> Function() action,
    String successHint,
  ) async {
    final client = ref.read(apiClientProvider);
    if (client == null || _busy) {
      return;
    }

    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(successHint)));
      // 终态后需要重新开始轮询
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(milliseconds: 1500),
        (_) => unawaited(_refresh(silent: true)),
      );
      await _refresh();
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.userMessage)));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final scheme = Theme.of(context).colorScheme;
    final title = task == null ? '任务' : (task.skill ?? task.type);
    final actions = <Widget>[
      // 内嵌：与栏头其它图标同规格（命中区 24、图标 14、8dp 圆角方形悬停底）。
      // Material 默认的 48 命中区在 40 高的栏头行里会顶出上下边界。
      // 窄屏整页：38dp 玻璃圆钮。
      if (widget.embedded)
        IconButton(
          tooltip: '刷新',
          onPressed: () => unawaited(_refresh()),
          style: _headerButtonStyle,
          iconSize: kPaneHeaderIconSize,
          icon: const Icon(Icons.refresh),
        )
      else
        MobileTopBarButton(
          icon: Icons.refresh,
          tooltip: '刷新',
          onPressed: () => unawaited(_refresh()),
        ),
      const SizedBox(width: 4),
    ];

    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：内嵌时底色由骨架的渐变透上来。
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded ? paneSurfaceColor(scheme) : null,
      appBar: widget.embedded
          ? null
          : MobileAppBar(title: title, actions: actions),
      body: Column(
        children: <Widget>[
          if (widget.embedded) EmbeddedToolbar(title: title, actions: actions),
          Expanded(
            child: task == null
                ? Center(
                    child: _error != null
                        ? Text(_error!)
                        : const CircularProgressIndicator(),
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      16 + MediaQuery.paddingOf(context).bottom,
                    ),
                    children: <Widget>[
                      _StateHeader(task: task),
                      if (task.pendingApproval != null) ...<Widget>[
                        const SizedBox(height: 12),
                        ApprovalCard(
                          approval: task.pendingApproval!,
                          busy: _busy,
                          onApprove: (remember, rememberScope) =>
                              _decide(
                                'approve',
                                remember: remember,
                                rememberScope: rememberScope,
                              ),
                          onReject: () => _decide('reject'),
                        ),
                      ],
                      if (task.errorHint != null) ...<Widget>[
                        const SizedBox(height: 12),
                        _ErrorCard(
                          code: task.errorCode ?? 'error',
                          hint: task.errorHint!,
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        '执行过程',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (task.plan.isEmpty)
                        Text(
                          '还没有计划。执行器接手后这里会显示每一步。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        )
                      else
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: <Widget>[
                              for (final step in task.plan)
                                _PlanStepTile(
                                  // 轮询会重建整棵列表：按 seq 对齐，展开状态才不丢。
                                  key: ValueKey<int>(step.seq),
                                  step: step,
                                  // 等待审批时执行侧仍停在同一步上，也算"在跑"。
                                  live:
                                      !task.isTerminal &&
                                      step.state == 'running',
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),
                      Text(
                        '产物',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (task.artifacts.isEmpty)
                        Text(
                          '暂无产物',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        )
                      else
                        Card(
                          child: Column(
                            children: <Widget>[
                              for (final artifact
                                  in _orderedArtifacts(task.artifacts))
                                _ArtifactTile(artifact: artifact),
                            ],
                          ),
                        ),
                      if (task.worktree != null) ...<Widget>[
                        const SizedBox(height: 16),
                        Text(
                          '工作树',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        _WorktreeCard(
                          worktree: task.worktree!,
                          canClean:
                              task.isTerminal &&
                              task.worktree!.exists &&
                              !_busy,
                          onClean: _cleanWorktree,
                        ),
                      ],
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        children: <Widget>[
                          if (task.canCancel)
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _cancel,
                              icon: const Icon(Icons.cancel_outlined),
                              label: const Text('取消任务'),
                            ),
                          if (task.canRetry)
                            FilledButton.icon(
                              onPressed: _busy ? null : _retry,
                              icon: const Icon(Icons.replay),
                              label: const Text('重试'),
                            ),
                        ],
                      ),
                      if (task.retryCount > 0) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          '已重试 ${task.retryCount} 次',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _StateHeader extends StatelessWidget {
  const _StateHeader({required this.task});

  final TaskView task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (task.state) {
      'succeeded' => scheme.primary,
      'failed' => scheme.error,
      'canceled' => scheme.outline,
      'needs_approval' => scheme.tertiary,
      'running' => scheme.secondary,
      _ => scheme.outline,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    taskStateLabel(task.state),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: AppWeight.semiBold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '创建于 ${formatTime(task.createdAt)}'
                    '${task.finishedAt != null ? ' · 结束于 ${formatTime(task.finishedAt!)}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            // 技能名长度由服务端决定（`skill:<name>`），窄屏上必须允许省略，
            // 否则它会以未约束的固有宽度把整行挤出去。
            Flexible(
              child: Text(
                task.type,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: AppText.of(context).mono(
                  size: AppFontSize.sm,
                  height: AppLineHeight.tight,
                  color: AppPalette.of(context).text.tertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.code, required this.hint});

  final String code;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(hint),
                const SizedBox(height: 4),
                Text(
                  code,
                  style: AppText.of(context).mono(
                    size: AppFontSize.sm,
                    height: AppLineHeight.tight,
                    color: AppPalette.of(context).text.secondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 产物条目：展开即拉取正文预览，右上角可「另存为」。
///
/// 正文按需拉取（列表只显示元信息）：产物可能有几百 KB，
/// 打开任务详情就把所有产物的全文读一遍是没必要的开销。
class _ArtifactTile extends ConsumerStatefulWidget {
  const _ArtifactTile({required this.artifact});

  final ArtifactView artifact;

  @override
  ConsumerState<_ArtifactTile> createState() => _ArtifactTileState();
}

class _ArtifactTileState extends ConsumerState<_ArtifactTile> {
  /// 预览上限：超过这个长度只提示可另存，不把整段塞进 SelectableText。
  static const int _previewLimit = 64 * 1024;

  String? _text;
  String? _error;
  bool _loading = false;
  bool _saving = false;

  bool get _previewable {
    final mime = widget.artifact.mime ?? '';
    final isText =
        mime.startsWith('text/') || mime == 'application/json' || mime.isEmpty;
    return isText && widget.artifact.size <= _previewLimit;
  }

  Future<void> _load() async {
    if (_text != null || _loading || !_previewable) {
      return;
    }
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await client.getBytes(
        '/api/artifacts/${widget.artifact.id}/content',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _text = utf8.decode(result.bytes, allowMalformed: true);
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.userMessage;
        _loading = false;
      });
    }
  }

  /// iPad / macOS 的分享面板需要一个锚点矩形，否则会抛异常。
  /// 取当前组件的位置与大小即可（用户点的就是这个按钮区域）。
  Rect? _shareOrigin() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _saveAs() async {
    if (_saving) {
      return;
    }
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await client.getBytes(
        '/api/artifacts/${widget.artifact.id}/content',
      );
      final mime = widget.artifact.mime ?? 'application/octet-stream';
      final name = artifactFileName(
        kind: widget.artifact.kind,
        id: widget.artifact.id,
        mime: mime,
      );

      final exported = await ref
          .read(artifactExporterProvider)
          .export(
            suggestedName: name,
            bytes: result.bytes,
            mime: mime,
            shareOrigin: _shareOrigin(),
          );
      if (!mounted) {
        return;
      }
      switch (exported.outcome) {
        case ExportOutcome.cancelled:
          return;
        case ExportOutcome.shared:
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(const SnackBar(content: Text('已通过系统分享导出')));
        case ExportOutcome.saved:
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text('已保存到 ${exported.path}')));
      }
      return;
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.userMessage);
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = _describeSaveFailure(error));
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = _describeSaveFailure(error));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final artifact = widget.artifact;

    return ExpansionTile(
      dense: true,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(artifactKindLabel(artifact.kind)),
      subtitle: Text(
        '${artifact.size} 字节 · ${artifact.mime ?? '未知类型'}'
        ' · ${formatTime(artifact.createdAt)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      onExpansionChanged: (expanded) {
        if (expanded) {
          unawaited(_load());
        }
      },
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: <Widget>[
        if (_error != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.error),
            ),
          )
        else if (!_previewable)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '不支持预览，可另存为',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else if (_loading)
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                _text ?? '',
                style: AppText.of(context)
                    .mono(size: AppFontSize.sm, height: AppLineHeight.normal),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _saving ? null : _saveAs,
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(_saving ? '保存中…' : '另存为'),
          ),
        ),
      ],
    );
  }
}

/// 产物的展示顺序：调试类内容排在前面。
///
/// 任务结束后用户最先要看的是"它到底跑了什么、改了什么"，而不是按写入
/// 时间碰运气。服务端返回顺序不动（其它客户端可能依赖），只在这一层重排；
/// 同档内保持原有相对顺序。
List<ArtifactView> _orderedArtifacts(List<ArtifactView> artifacts) {
  const rank = <String, int>{
    'run_log': 0,
    'change_summary': 1,
    'diff': 2,
  };

  final indexed = artifacts.indexed.toList()
    ..sort((left, right) {
      final leftRank = rank[left.$2.kind] ?? 99;
      final rightRank = rank[right.$2.kind] ?? 99;
      if (leftRank != rightRank) {
        return leftRank.compareTo(rightRank);
      }
      return left.$1.compareTo(right.$1);
    });

  return <ArtifactView>[for (final item in indexed) item.$2];
}

/// 把保存失败翻译成用户能行动的一句话。
///
/// 沙箱缺 `files.user-selected.read-write` 时的报错是 "Operation not permitted"，
/// 用户看到只会以为文件坏了；实际情况是客户端构建旧了，需要重装/重编。
String _describeSaveFailure(Object error) {
  final text = error.toString();
  final denied =
      text.contains('Operation not permitted') ||
      text.contains('Permission denied') ||
      text.contains('permission') ||
      text.contains('errno = 1') ||
      text.contains('errno = 13');
  if (denied) {
    return '保存被系统拒绝：当前客户端可能缺少文件写入权限，请更新到最新构建后重试';
  }
  return '保存失败：$text';
}

/// 工作树区块：路径与分支名，都能一键复制。
///
/// 存在的意义是"分支去哪了"这类问题：分支只活在这棵独立的克隆里，
/// 批准合并时才被 fetch 进原仓库。把路径摆在眼前，用户不必再猜。
class _WorktreeCard extends StatelessWidget {
  const _WorktreeCard({
    required this.worktree,
    required this.canClean,
    required this.onClean,
  });

  final WorktreeView worktree;
  final bool canClean;
  final VoidCallback onClean;

  Future<void> _copy(BuildContext context, String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    Widget row(IconData icon, String title, String value) {
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        leading: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        title: Text(title, style: theme.textTheme.labelMedium),
        subtitle: Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.of(context)
              .mono(size: AppFontSize.sm, height: AppLineHeight.normal),
        ),
        trailing: IconButton(
          tooltip: '复制',
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          onPressed: () => _copy(context, value, title),
        ),
      );
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          row(Icons.folder_open, '工作树目录', worktree.path),
          row(Icons.call_split, '任务分支', worktree.branch),
          if (!worktree.exists)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '工作树目录已不存在（清理过或没有准备成功）',
                style: AppText.of(context).hint.copyWith(
                  color: AppPalette.of(context).text.secondary,
                ),
              ),
            ),
          if (canClean)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
                child: TextButton.icon(
                  onPressed: onClean,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('清理现场'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一个计划步骤：状态、过程摘要与"多久没更新"。
///
/// 展开状态必须自己管：`ExpansionTile.initiallyExpanded` 只在创建时生效，
/// 而"正在执行的步骤"是任务跑起来之后才出现的。用户手动收起过之后，
/// 轮询重建不能再把它顶开——那等于跟用户抢控制权。
class _PlanStepTile extends StatefulWidget {
  const _PlanStepTile({super.key, required this.step, required this.live});

  final PlanStepView step;

  /// 任务未结束且这一步正在跑。
  final bool live;

  @override
  State<_PlanStepTile> createState() => _PlanStepTileState();
}

class _PlanStepTileState extends State<_PlanStepTile> {
  /// 过程区最多直接展示 6 行，再多就滚动：否则计划列表会被挤出屏幕。
  static const int _maxVisibleLines = 6;

  /// 超过这个秒数没有新输出就提示"仍在执行"。
  static const int _staleSeconds = 15;

  bool _expanded = false;
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.live;
  }

  @override
  void didUpdateWidget(covariant _PlanStepTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 步骤"后来才开始跑"时自动展开；用户手动收起过就不再抢回来。
    if (widget.live && !oldWidget.live && !_touched) {
      _expanded = true;
    }
  }

  int _silentSeconds(int? updatedAt) {
    if (updatedAt == null) {
      return 0;
    }
    return (DateTime.now().millisecondsSinceEpoch - updatedAt) ~/ 1000;
  }

  String _clock(int millis) {
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final hasDetail = step.hasOutput;
    final palette = AppPalette.of(context);
    final stale =
        widget.live && _silentSeconds(step.updatedAt) >= _staleSeconds;

    final subtitle = StringBuffer(planStepLabel(step.state));
    final updatedAt = step.updatedAt;
    if (updatedAt != null) {
      subtitle.write(' · 最后更新 ${_clock(updatedAt)}');
    }
    if (stale) {
      subtitle.write(' · 已超过 $_staleSeconds 秒没有新输出，仍在执行');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: hasDetail
              ? () => setState(() {
                  _touched = true;
                  _expanded = !_expanded;
                })
              : null,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 10, hasDetail ? 8 : 16, 10),
            child: Row(
              children: <Widget>[
                _StepIcon(state: step.state),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(step.name),
                      const SizedBox(height: 2),
                      Text(
                        subtitle.toString(),
                        style: AppText.of(context).meta.copyWith(
                          color: stale ? palette.status.warning : null,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasDetail)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: palette.text.tertiary,
                  ),
              ],
            ),
          ),
        ),
        if (_expanded && hasDetail)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(
                // 6 行 × (11.5pt × 1.45) ≈ 100，加上下 10 的内边距正好 120。
                maxHeight: step.output!.split('\n').length > _maxVisibleLines
                    ? 120
                    : double.infinity,
              ),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  step.output!,
                  style: AppText.of(context).mono(
                    size: AppFontSize.sm,
                    height: AppLineHeight.code,
                    color: palette.text.secondary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StepIcon extends StatelessWidget {
  const _StepIcon({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Icon(
      switch (state) {
        'done' => Icons.check_circle,
        'running' => Icons.play_circle_fill,
        'failed' => Icons.error,
        'skipped' => Icons.remove_circle_outline,
        _ => Icons.radio_button_unchecked,
      },
      size: 20,
      color: switch (state) {
        'done' => scheme.primary,
        'running' => scheme.secondary,
        'failed' => scheme.error,
        _ => scheme.outlineVariant,
      },
    );
  }
}
