import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/project_providers.dart';
import '../conversations/conversations_page.dart';
import 'shell_layout_state.dart';

/// 新建会话要落到哪个项目：优先当前选中项所属的那个，其次列表第一个。
///
/// 侧栏那颗整行宽的「新建会话」与中栏栏头的图标按钮共用这一份判断：
/// 两处各写一套，迟早出现"同一个动作，左栏展开与收起时落到不同项目"。
/// 列表为空时返回 `null`——此时调用方建无归属直聊，不再把按钮置灰。
Project? hostProjectFor(List<Project> items, ShellTarget? target) {
  if (items.isEmpty) {
    return null;
  }
  for (final project in items) {
    if (target != null && project.id == target.projectId) {
      return project;
    }
  }
  return items.first;
}

/// 新建会话的结果。窄屏整页详情页拿到它以后要自己 push 一条会话页。
typedef CreatedConversation = ({String id, String title});

/// 新开一条会话，并把它选中到中栏。
///
/// 这是「新建会话」的唯一实现：请求、刷新与落点只写一遍，入口再多
/// （侧栏按钮 / 栏头图标按钮 / 项目详情页头）也不会出现"从侧栏建刷新了这个、
/// 从栏头建漏了那个"。
///
/// [host] 为 `null` 时不带 `project_id`，建一条**无归属直聊**：
/// 聊天不该被目录结构卡住，当前模式一个项目都没有时同样能开会话。
///
/// 返回新建会话的 id 与标题，供**窄屏整页**宿主使用：那种形态下详情页是压在
/// 骨架上的独立路由，只改 `shellTargetProvider` 用户看不到，调用方要据此
/// `Navigator.push(ChatPage(...))`。宽屏内嵌形态忽略返回值即可。
/// 失败或未登录返回 `null`。
Future<CreatedConversation?> createConversation(
  BuildContext context,
  WidgetRef ref, {
  Project? host,
}) async {
  final client = ref.read(apiClientProvider);
  if (client == null) {
    return null;
  }

  try {
    // 与项目详情里的入口一致：不传标题，服务端给占位值。
    final created = await client.postJson(
      '/api/conversations',
      <String, dynamic>{if (host != null) 'project_id': host.id},
    );
    // 先确认调用方还在树上：await 之后这个 `ref` 可能已经 dispose，
    // 栏头那颗按钮所在的页面也会随切换被换掉。
    if (!context.mounted) {
      return null;
    }
    final id = created['id'] as String? ?? '';
    final title = created['title'] as String? ?? '新会话';
    if (host != null) {
      ref.invalidate(conversationsProvider(host.id));
      ref.invalidate(projectProvider(host.id));
    } else {
      // 无归属会话不进任何项目视图，侧栏只靠「对话」分组收拢它们。
      ref.invalidate(unassignedConversationsProvider);
    }
    ref
        .read(shellTargetProvider.notifier)
        .select(
          ConversationTarget(
            // 空串 = 无归属：与会话页的侧栏高亮、后退落点同一套口径。
            projectId: host?.id ?? '',
            conversationId: id,
            title: title,
            projectPath: host?.path,
            // 带着项目对象：会话页的「关闭 / 删除」要回到它那一页。
            project: host,
          ),
        );
    return (id: id, title: title);
  } on ApiException catch (error) {
    if (!context.mounted) {
      return null;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error.userMessage)));
    return null;
  }
}
