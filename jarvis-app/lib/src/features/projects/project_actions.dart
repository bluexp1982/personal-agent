import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/models.dart';
import '../../core/project_providers.dart';
import '../../core/session.dart';
import '../../core/ui/rename_dialog.dart';
import '../shell/selection_toolbar.dart';

// 项目级动作的公共实现：重命名 / 复制路径 / 删除。
//
// 这些动作现在有两个入口——项目详情页栏头菜单、宽屏侧栏项目行的「项目操作」
// 菜单。每个入口各写一遍「弹框 → 请求 → 失效 provider」，迟早出现改了项目名
// 侧栏不刷新、或者一边删了项目另一边还把旧 target 留在后退栈里。
//
// 这一层只做**对话框与请求**，不决定导航：内嵌页要交给外壳收起、整页形态要
// `pop`，侧栏要清 target——落点各不相同，由调用方在拿到返回值后自己收尾。

/// 重命名项目：弹重命名框 → `PATCH /api/projects/{id}`。
///
/// 返回更新后的项目（服务端回包）；用户取消、名字没变、未登录或请求失败时
/// 返回 `null`。失败已弹 SnackBar，调用方不需要再报一次。
Future<Project?> renameProject(
  BuildContext context,
  WidgetRef ref,
  Project project,
) async {
  final name = await showRenameDialog(
    context,
    title: '重命名项目',
    label: '名字',
    initialValue: project.name,
  );

  final trimmed = name?.trim();
  if (trimmed == null ||
      trimmed.isEmpty ||
      !context.mounted ||
      trimmed == project.name) {
    return null;
  }

  final client = ref.read(apiClientProvider);
  if (client == null) {
    return null;
  }

  try {
    final json = await client.patchJson(
      '/api/projects/${project.id}',
      <String, dynamic>{'name': trimmed},
    );
    ref.invalidate(projectsProvider);
    ref.invalidate(projectProvider(project.id));
    return Project.fromJson(json);
  } on ApiException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
    return null;
  }
}

/// 复制项目目录：写系统剪贴板，并提示一句。
///
/// 复制的是**绝对路径**而不是项目名：这条菜单的用途是把目录粘到终端或
/// Finder 里去，名字粘出去没有意义。
Future<void> copyProjectPath(BuildContext context, Project project) async {
  await Clipboard.setData(ClipboardData(text: project.path));
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('已复制目录路径')));
}

/// 删除前确认。与「删除会话 / 任务」共用 [confirmDeleteDialog] 的样式与措辞，
/// 只有条目数量固定为 1。
///
/// 拆成独立一步而不是并进 [deleteProject]：项目详情页需要在**确认之后、
/// 请求之前**点亮忙碌态，Sidebar 也要在这两步之间决定要不要收起菜单。
Future<bool> confirmDeleteProject(BuildContext context, Project project) {
  return confirmDeleteDialog(
    context,
    title: '删除「${project.name}」？',
    message:
        '项目下的会话与任务会一起从列表消失，数据本身保留在服务端。\n\n'
        '如果还有未结束的任务，删除会失败——请先取消它。',
    count: 1,
  );
}

/// 删除项目：`DELETE /api/projects/{id}` 并失效项目列表。
///
/// 返回是否真的删掉了。调用方负责收尾（清空右侧 / pop 整页 / 从侧栏展开集合
/// 里移除）。失败已弹 SnackBar。
Future<bool> deleteProject(
  BuildContext context,
  WidgetRef ref,
  Project project,
) async {
  final client = ref.read(apiClientProvider);
  if (client == null) {
    return false;
  }

  try {
    await client.delete('/api/projects/${project.id}');
    ref.invalidate(projectsProvider);
    return true;
  } on ApiException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.userMessage)));
    }
    return false;
  }
}
