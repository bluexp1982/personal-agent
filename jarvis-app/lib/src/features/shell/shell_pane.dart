import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../canvas/canvas_demo_page.dart';
import '../memory/memory_page.dart';
import '../recordings/recording_detail_page.dart';
import '../recordings/recording_session_page.dart';
import '../recordings/recordings_page.dart';
import '../tasks/task_detail_page.dart';
import '../projects/project_detail_page.dart';
import 'empty_chat_page.dart';
import 'shell_layout_state.dart';

/// 宽屏中栏：按侧栏的选中项原地切换，不再叠一层整页。
///
/// 各个详情页都带 `key`：不加 key 时 Flutter 会按"位置 + 类型"复用 State，
/// 从一个项目切到另一个项目会沿用上一个的 Tab 与滚动位置，看起来像串台。
///
/// 会话**不在**这里：它是骨架层的 `ChatWindowLayer`。同一个聊天窗口要能停靠
/// 中栏、也要能缩成浮窗浮到任意一栏之上，挂在 `Expanded` 里就浮不出去，
/// 而换一个父级又会把消息、流与输入草稿全部重建。
///
/// 录音三页与记忆也在这里：它们的入口都在左栏，窄屏没有中栏时才退回
/// `Navigator.push`（见 `home_shell.dart` 的宽窄分支）。设置不在此列：
/// 宽屏是浮层（`showSettingsDialog`），窄屏是「我的」下面的一级列表。
class ShellPane extends ConsumerWidget {
  const ShellPane({
    super.key,
    required this.session,
    this.canvasImmersive = false,
  });

  /// 设置页要一份已登录会话。由骨架直接传下来而不是在这里读 provider：
  /// 骨架本来就拿着同一个对象，再读一次只多一个"未就绪"分支。
  final SessionState session;

  /// 中栏的画布正占着沉浸全屏。
  ///
  /// 由骨架判定后传进来而不是在这里读 provider：能不能全屏取决于"窗口够不够宽、
  /// 中栏是不是画布"，那是骨架的布局知识；这里只负责把结论交给画布页。
  final bool canvasImmersive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(shellTargetProvider);
    if (target == null) {
      return const EmptyChatPage();
    }

    void select(ShellTarget next) =>
        ref.read(shellTargetProvider.notifier).select(next);

    return switch (target) {
      // 会话由 `ChatWindowLayer` 渲染，这里只占住中栏这一格：
      // 宽度仍由外层 `Expanded` 保证，右栏不会因此左移。
      ConversationTarget() => const SizedBox.shrink(),
      ProjectTarget() => ProjectDetailPage(
        key: ValueKey<String>('project-${target.projectId}'),
        project: target.project,
        embedded: true,
        onOpenConversation: (conversation) => select(
          ConversationTarget(
            projectId: target.projectId,
            conversationId: conversation.id,
            title: conversation.title,
            projectPath: target.project.path,
            // 带上项目对象：会话页的「关闭 / 删除」要回到它那一页。
            project: target.project,
          ),
        ),
        onOpenTask: (taskId) => select(
          TaskTarget(projectId: target.projectId, taskId: taskId, title: '任务'),
        ),
        // 关闭 = 只把右侧收起来：项目仍留在侧栏，随时能再点开。
        onClose: () => ref.read(shellTargetProvider.notifier).clear(),
        // 删掉的项目不该继续占着右侧，也不该留在后退栈里：
        // 先导航（会把当前页压进后退栈）再剪枝，顺序反过来等于白剪。
        onDeleted: () {
          final targets = ref.read(shellTargetProvider.notifier);
          targets.clear();
          targets.forgetProject(target.projectId);
        },
      ),
      TaskTarget() => TaskDetailPage(
        key: ValueKey<String>('task-${target.taskId}'),
        taskId: target.taskId,
        embedded: true,
      ),
      RecordingsTarget() => RecordingsPage(
        key: const ValueKey<String>('recordings'),
        embedded: true,
        onOpenDetail: (local, server) =>
            select(RecordingDetailTarget(local: local, server: server)),
        onOpenSession: () => select(const RecordingSessionTarget()),
      ),
      RecordingDetailTarget() => RecordingDetailPage(
        // 换一条录音要换 State：播放器、Tab 与滚动位置都不该沿用上一条。
        key: ValueKey<String>('recording-${target.key}'),
        local: target.local,
        server: target.server,
        embedded: true,
        // 删掉的录音不该留在一个不存在的详情上，也不该退得回去：
        // 先回列表（会把详情压进后退栈）再剪枝，顺序反过来等于白剪。
        onDeleted: () {
          select(const RecordingsTarget());
          ref.read(shellTargetProvider.notifier).forgetRecording(target.key);
        },
      ),
      RecordingSessionTarget() => RecordingSessionPage(
        key: const ValueKey<String>('recording-session'),
        embedded: true,
        // 收起 = 回列表：录音本身在全局控制器里，不受这一页存亡影响。
        onCollapse: () => select(const RecordingsTarget()),
        onStopped: (recording) =>
            select(RecordingDetailTarget(local: recording)),
      ),
      MemoryTarget() => const MemoryListPage(
        key: ValueKey<String>('memory'),
        embedded: true,
      ),
      CanvasTarget() => CanvasDemoPage(
        key: const ValueKey<String>('canvas-demo'),
        embedded: true,
        immersive: canvasImmersive,
      ),
    };
  }
}
