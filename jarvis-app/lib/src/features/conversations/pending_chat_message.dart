import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'attachment_embed.dart';

/// 空态里敲下、但会话页还没发出的第一句话。
///
/// [skill] 是输入栏里选中的技能标签（没有则为 null）。必须一起带过去：
/// 标签是富文本里的一个节点，转成纯文本后就没了，只交文本等于把"用哪个技能"
/// 这件事静默丢掉——用户会看到自己明明选了技能，回车却没反应。
///
/// [attachments] 同理：芯片是文档里的节点，纯文本里只剩一个占位符。
/// 不带过去的话，用户附好文件按回车，附件会在切页那一下凭空消失。
typedef PendingChatMessage = ({
  String conversationId,
  String text,
  String? skill,
  List<AttachmentEmbed> attachments,
});

/// 「聊天」空态页与新建会话之间的一次性交接。
///
/// 空态页先建好会话、把这句话登记在这里，随后的会话页在历史加载完成后
/// 用 [PendingChatMessageController.take] 取走并发出。
///
/// 为什么不让空态页自己发：发送、流式增量、停止、标题刷新全在会话页那套
/// 状态机里，空态页自己发就得再实现一遍；而先发再跳转，跳转会把正在跑的
/// 流转播打断，半截回答直接丢。
///
/// [PendingChatMessageController.take] 取走即清空：后退回到这条会话时
/// 不会把同一句话再发一遍。
final pendingChatMessageProvider =
    NotifierProvider<PendingChatMessageController, PendingChatMessage?>(
      PendingChatMessageController.new,
    );

class PendingChatMessageController extends Notifier<PendingChatMessage?> {
  @override
  PendingChatMessage? build() => null;

  /// 登记一句话。空白且没有技能、也没有附件时忽略。
  ///
  /// 「只有技能、没有文字」与「只有附件、没有文字」都是合法输入：
  /// 前者技能自带流程，后者"就发这张图"本身就是完整意图，
  /// 都不该被当成空消息丢掉。
  void put(
    String conversationId,
    String text, {
    String? skill,
    List<AttachmentEmbed> attachments = const <AttachmentEmbed>[],
  }) {
    final trimmed = text.trim();
    if (conversationId.isEmpty ||
        (trimmed.isEmpty && skill == null && attachments.isEmpty)) {
      return;
    }
    state = (
      conversationId: conversationId,
      text: trimmed,
      skill: skill,
      attachments: attachments,
    );
  }

  /// 取走属于 [conversationId] 的那句话并清空；不是它就原样留着。
  PendingChatMessage? take(String conversationId) {
    final current = state;
    if (current == null || current.conversationId != conversationId) {
      return null;
    }
    state = null;
    return current;
  }
}
