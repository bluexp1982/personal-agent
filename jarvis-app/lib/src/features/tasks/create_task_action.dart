import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/code_providers.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import '../../core/session.dart';
import '../conversations/approval_mode.dart';
import 'code_task_input_dialog.dart';
import 'task_detail_page.dart';

/// 派一件事：选技能与会话 → 编码任务再补一张表单 → POST `/api/tasks`。
///
/// 从 `TasksPage._createTask` 抽出来：任务列表的悬浮按钮与项目详情页页头的
/// 「新建」圆钮共用同一份实现。两边各写一遍的话，迟早出现「从列表派会刷新、
/// 从页头派漏了谁」这种只在某一个入口复现的差异。
///
/// 成功后打开详情的方式按宿主分：
/// - 传了 [onOpenTask]（宽屏中栏原地切换）就交给它；
/// - 没传（窄屏整页）在这里 push 任务详情，与列表项点击一致。
///
/// 列表刷新留给调用方：`tasksProvider` 定义在 `tasks_page.dart`，
/// 这里反向 import 页面会绕成环，调用方拿到返回值后自己 invalidate 更清楚。
/// 返回新建任务的 id；用户取消或请求失败返回 `null`。
Future<String?> createTask(
  BuildContext context,
  WidgetRef ref, {
  required String projectId,
  required String mode,
  String? projectPath,
  ValueChanged<String>? onOpenTask,
}) async {
  final request = await showDialog<_NewTaskRequest>(
    context: context,
    builder: (_) => _NewTaskDialog(mode: mode, projectId: projectId),
  );
  if (request == null) {
    return null;
  }

  // 编码任务要的是"要改什么"，仓库由项目提供（服务端也会按项目覆盖 repo）。
  Map<String, dynamic> input = <String, dynamic>{'submit': request.submit};
  if (request.skill == 'code-task') {
    if (!context.mounted) {
      return null;
    }
    // 清单没预热过时这里会真的发一次请求：先取再开弹窗，
    // 否则第一次打开没有"执行方式"、第二次才有，看着像选择器时灵时不灵。
    // 拉不到就按"自动"处理——这是可选增强，不该挡住派单。
    final providers = await readCodeProviders(ref);
    if (!context.mounted) {
      return null;
    }
    final code = await showCodeTaskInputDialog(
      context,
      projectPath: projectPath,
      providers: providers,
    );
    if (code == null) {
      return null;
    }
    // 任务页没有权限菜单：沿用该会话在输入栏里的选择（没选过就是请求审批）。
    // 留空的执行方式交给服务端按任务形态路由；显式指定时由服务端校验能不能派。
    input = codeTaskInputJson(
      input: code,
      approval: ref.read(composerApprovalProvider(request.conversationId)),
    );
  }

  final client = ref.read(apiClientProvider);
  if (client == null) {
    return null;
  }

  try {
    final created = await client.postJson('/api/tasks', <String, dynamic>{
      'conversation_id': request.conversationId,
      'type': 'skill:${request.skill}',
      'skill': request.skill,
      'input': input,
      'idempotency_key':
          'ui-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
    });
    ref.invalidate(projectProvider(projectId));

    final taskId = created['id'] as String? ?? '';
    if (onOpenTask != null) {
      onOpenTask(taskId);
      return taskId;
    }
    if (!context.mounted) {
      return taskId;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TaskDetailPage(taskId: taskId)),
    );
    return taskId;
  } on ApiException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
    return null;
  }
}

class _NewTaskRequest {
  const _NewTaskRequest({
    required this.conversationId,
    required this.skill,
    required this.submit,
  });

  final String conversationId;
  final String skill;
  final bool submit;
}

class _NewTaskDialog extends ConsumerStatefulWidget {
  const _NewTaskDialog({required this.mode, required this.projectId});

  /// 项目模式决定技能清单：普通项目下服务端不会返回编码任务。
  final String mode;
  final String projectId;

  @override
  ConsumerState<_NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends ConsumerState<_NewTaskDialog> {
  List<String> _skills = <String>[];
  List<ConversationSummary> _conversations = <ConversationSummary>[];
  String? _skill;
  String? _conversationId;
  bool _submit = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = '尚未登录';
      });
      return;
    }

    try {
      // 技能清单按模式过滤、会话按项目过滤：这里列出的都是"能在当前项目里办的事"。
      final skills = await client.getJsonArray(
        '/api/skills',
        query: <String, String>{'mode': widget.mode},
      );
      final conversations = await client.getJson(
        '/api/conversations',
        query: <String, String>{
          'limit': '50',
          'project_id': widget.projectId,
        },
      );

      final conversationItems =
          conversations['items'] as List<dynamic>? ?? const <dynamic>[];

      if (!mounted) {
        return;
      }
      setState(() {
        _skills = skills
            .map((item) => item['name'] as String? ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
        _conversations = conversationItems
            .whereType<Map<String, dynamic>>()
            .map(ConversationSummary.fromJson)
            .toList();
        _skill = _skills.isEmpty ? null : _skills.first;
        _conversationId = _conversations.isEmpty
            ? null
            : _conversations.first.id;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('派一件事'),
      // 只封上界不写死宽度：手机上 Dialog 会被系统压到屏幕内，
      // 写死 380 会在窄屏上变成"内容比可用宽度还宽"。
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: _loading
              ? const SizedBox(
                  height: 80,
                  child: Center(child: CircularProgressIndicator()),
                )
              : _error != null
              ? Text(_error!)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    DropdownButtonFormField<String>(
                      initialValue: _skill,
                      // isExpanded 必须为 true，否则按钮宽度由最长的 item 决定，
                      // 长名称会把下拉框撑出对话框（ellipsis 也不会生效）。
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '用哪个技能',
                        border: OutlineInputBorder(),
                      ),
                      items: _skills
                          .map(
                            (name) => DropdownMenuItem<String>(
                              value: name,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() => _skill = value),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _conversationId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '挂在哪个会话',
                        border: OutlineInputBorder(),
                      ),
                      items: _conversations
                          .map(
                            (item) => DropdownMenuItem<String>(
                              value: item.id,
                              child: Text(
                                item.title,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _conversationId = value),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _submit,
                      onChanged: (value) => setState(() => _submit = value),
                      title: const Text('提交前需要我确认'),
                      subtitle: const Text('只读任务可以不勾；涉及提交的动作必须勾选'),
                    ),
                  ],
                ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_skill == null || _conversationId == null)
              ? null
              : () => Navigator.of(context).pop(
                  _NewTaskRequest(
                    conversationId: _conversationId!,
                    skill: _skill!,
                    submit: _submit,
                  ),
                ),
          child: const Text('创建'),
        ),
      ],
    );
  }
}
