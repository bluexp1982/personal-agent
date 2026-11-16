import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 输入栏「权限」菜单的三个选项，也是下发给服务端的 `input.approval` 取值。
///
/// 三档回答的是同一个问题：**这次任务要不要人来批**。沙箱宽严是另一个问题，
/// 不混进这张菜单——否则用户无法判断"我到底放开了什么"。
abstract final class ApprovalModes {
  /// 请求审批：命中审批档就要人点（默认，与改造前完全一致）。
  static const String request = 'request';

  /// 帮我审批：常规操作自动放行，只对安装 / 删除 / 危险脚本等问人。
  static const String auto = 'auto';

  /// 完全放行：工具级不再逐条询问，只保留合并前确认。
  ///
  /// 只存在内存里，且必须经过二次确认才允许切换：重启回默认的「请求审批」。
  static const String trust = 'trust';

  static const List<String> all = <String>[request, auto, trust];

  /// 触发器上显示的短文案。
  static String labelOf(String value) => switch (value) {
    auto => '帮我审批',
    trust => '完全放行',
    _ => '请求审批',
  };

  /// 菜单条目的一句用途说明，照参考图的写法。
  static String describe(String value) => switch (value) {
    auto => '只对安装、删除、危险脚本等风险操作问你',
    trust => '工具调用不再逐条问你，改动仍需确认合并',
    _ => '编辑工作树外文件、联网、执行命令时都问你',
  };
}

/// 选「完全放行」前的二次确认。返回 true 才真正切换。
///
/// 这是三档里唯一会放开"任意工具调用"的选项，必须让人在切换的那一刻
/// 看到代价：项目外读写、联网、执行命令都会直接进行，只剩合并这一道闸。
Future<bool> confirmFullAccess(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('完全放行这个会话？'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: const Text(
          '本任务的工具调用不再逐条确认：读写项目外的文件、执行命令、联网都会直接进行。\n\n'
          '改动仍然在独立工作树里，合并回原分支前还会再问你一次。',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('完全放行'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 「聊天」空态页的权限占位 key。
///
/// 那时还没有会话 id，但用户可能先选好审批方式再敲第一句；选中后会按真实
/// 会话 id 复制一份（见 `EmptyChatPage`）。`chat-draft` 不会与 `conv_*` 撞 id。
const String kDraftChatApprovalKey = 'chat-draft';

/// 按会话记住权限选择。
///
/// 用 family 而不是一个控制器管 Map：会话页、任务页都按 `conversationId` 取，
/// 互不牵连；切走再切回来不会把选择丢掉。
///
/// 只存在内存里：应用重启回默认「请求审批」。要跨设备记住就得写服务端，
/// 那是另一个量级的改动（迁移 + API），本次刻意不做。
final composerApprovalProvider =
    NotifierProvider.family<ComposerApprovalController, String, String>(
      ComposerApprovalController.new,
    );

/// 单个会话的审批模式。
class ComposerApprovalController extends Notifier<String> {
  ComposerApprovalController(this.conversationId);

  /// 本状态所属的会话 id。
  final String conversationId;

  @override
  String build() {
    // 会话页被重建（切标签、收起面板）时不该把用户的选择清回默认。
    ref.keepAlive();
    return ApprovalModes.request;
  }

  /// 切换模式。认不出来的值直接忽略：URL/深链塞进来的脏数据不该放宽审批。
  void select(String value) {
    if (!ApprovalModes.all.contains(value) || value == state) {
      return;
    }
    state = value;
  }
}
