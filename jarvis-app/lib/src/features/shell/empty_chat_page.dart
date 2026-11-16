import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/model_providers.dart';
import '../../core/session.dart';
import '../conversations/approval_mode.dart';
import '../conversations/chat_composer_area.dart';
import '../conversations/composer_reasoning.dart';
import '../conversations/composer_text.dart';
import '../conversations/conversations_page.dart';
import '../conversations/new_session_stage.dart';
import '../conversations/pending_chat_message.dart';
import 'embedded_toolbar.dart';
import 'pane_surface.dart';
import 'shell_layout_state.dart';

/// 中栏空态：什么都没有选（或当前模式下连一个项目都没有）时的聊天开场。
///
/// 不再画"从左侧选择会话或项目"的引导卡：空态本身就是可以立刻开聊的地方，
/// 用户不必先在项目里建一个会话。发送时建一条**无归属会话**
/// （不挂项目，见服务端 `ConversationCreate.project_id` 可省略），
/// 首句经 `pendingChatMessageProvider` 交给会话页发出——发送与流式只保留一处实现。
///
/// 栏头标题是「聊天」而不是「新会话」：此刻还没有会话，它描述的是这一栏在做什么。
class EmptyChatPage extends ConsumerStatefulWidget {
  const EmptyChatPage({super.key});

  /// 栏头标题。
  static const String title = '聊天';

  @override
  ConsumerState<EmptyChatPage> createState() => _EmptyChatPageState();
}

class _EmptyChatPageState extends ConsumerState<EmptyChatPage> {
  final QuillController _input = QuillController.basic();

  /// 正在建会话：按钮转圈并挡住重复提交，避免连点建出两条。
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 切换审批方式。「完全放行」必须先过二次确认，取消则保持原值。
  Future<void> _selectPermission(String value) async {
    if (value == ApprovalModes.trust && !await confirmFullAccess(context)) {
      return;
    }
    if (!mounted) {
      return;
    }
    ref
        .read(composerApprovalProvider(kDraftChatApprovalKey).notifier)
        .select(value);
  }

  /// 发第一句：建无归属会话 → 登记首句 → 把中栏切到该会话。
  ///
  /// 失败时保留输入内容：这是一句还没落库的话，丢了用户就得重敲。
  Future<void> _send() async {
    final text = composerText(_input);
    // 技能标签是富文本节点，`composerText` 只取文字——它不会出现在 `text` 里，
    // 必须单独取出来交给会话页，否则"选了技能按回车没反应"。
    final skill = firstSkillName(_input);
    // 附件同理：芯片也是文档节点，不带过去就会在切页那一下凭空消失。
    final attachments = attachmentEmbeds(_input);
    if (attachments.any((embed) => embed.uploading)) {
      if (!_sending) {
        _toast('还有附件正在上传，请稍等一下');
      }
      return;
    }
    if (skill != null && attachments.isNotEmpty) {
      if (!_sending) {
        _toast('技能标签与附件不能同时发送，请先移除其中一项');
      }
      return;
    }
    // 只有标签、没打字也是合法的一次派单：技能自带流程；只有附件也同理。
    //
    // 这里**必须给反馈**：输入框看着"有东西"（标签）却因为标签没被识别成
    // 技能而当成空消息时，静默 return 会让人以为"按了回车没反应"，
    // 完全无从判断是哪一环断了。发送按钮在空输入时是灰的，能走到这里的
    // 只有回车，所以这句提示不会在正常输入时打扰人。
    if (text.isEmpty && skill == null && attachments.isEmpty) {
      if (!_sending) {
        _toast('先输入内容，或用 @ 选一个技能');
      }
      return;
    }
    if (_sending) {
      return;
    }
    final client = ref.read(apiClientProvider);
    if (client == null) {
      _toast('还没连上服务端，请稍后重试');
      return;
    }

    setState(() => _sending = true);
    try {
      // 不带 project_id：无归属直聊不依赖任何项目，任何模式下都能开聊。
      final created = await client.postJson(
        '/api/conversations',
        const <String, dynamic>{},
      );
      final conversationId = created['id'] as String? ?? '';
      if (!mounted) {
        return;
      }
      if (conversationId.isEmpty) {
        setState(() => _sending = false);
        _toast('新建会话失败，请重试');
        return;
      }

      // 输入栏里先选好的审批方式跟着这次会话走：用户不必在会话页再选一遍。
      final approval = ref.read(composerApprovalProvider(kDraftChatApprovalKey));
      if (approval != ApprovalModes.request) {
        ref
            .read(composerApprovalProvider(conversationId).notifier)
            .select(approval);
      }

      // 推理等级同理：在空态选好的档位必须跟着首句进会话，否则用户会看到
      // 自己刚选的「最高」在切页那一下变回「高」。
      final reasoning = ref.read(
        composerReasoningProvider(kDraftChatReasoningKey),
      );
      if (reasoning != ReasoningLevels.fallback) {
        ref
            .read(composerReasoningProvider(conversationId).notifier)
            .select(reasoning);
      }

      ref.invalidate(unassignedConversationsProvider);
      ref
          .read(pendingChatMessageProvider.notifier)
          .put(
            conversationId,
            text,
            skill: skill,
            attachments: attachments,
          );

      // 先清空再切页：切页后本组件会被销毁，留着文本只会让下次回到空态时重发。
      clearComposer(_input);
      setState(() => _sending = false);

      ref
          .read(shellTargetProvider.notifier)
          .select(
            ConversationTarget(
              // 空串 = 无归属：侧栏「对话」分组据此收拢这批会话。
              projectId: '',
              conversationId: conversationId,
              title: created['title'] as String? ?? '新会话',
            ),
          );
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _sending = false);
      _toast(error.userMessage);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      key: kShellEmptyChatKey,
      // 与内嵌会话页同一层半透明栏底：骨架的模式渐变透得上来，首条消息
      // 到达、页面换成会话页时底色也不会跳一下。
      backgroundColor: paneSurfaceColor(scheme),
      body: Column(
        children: <Widget>[
          const EmbeddedToolbar(
            title: EmptyChatPage.title,
            emphasizeTitle: true,
            actions: <Widget>[],
          ),
          Expanded(
            child: NewSessionStage(
              // 中线按整个窗口算：上面那条栏头也要算进"窗口"里。
              chromeAbove: kPaneHeaderHeight,
              composer: ChatComposerArea(
                controller: _input,
                sending: _sending,
                // 这里不发流：会话页接手后才会有可停止的这一轮。
                onSend: _send,
                onStop: () {},
                permission: ref.watch(
                  composerApprovalProvider(kDraftChatApprovalKey),
                ),
                onPermissionChanged: _selectPermission,
                reasoning: ref.watch(
                  composerReasoningProvider(kDraftChatReasoningKey),
                ),
                onReasoningChanged: (value) => ref
                    .read(
                      composerReasoningProvider(kDraftChatReasoningKey).notifier,
                    )
                    .select(value),
                // 还没有回答：分子为 0，但分母要照当前模型给出来，
                // 否则悬停会提示"窗口未配置"——其实是还没聊，不是没配。
                contextWindow: ref.watch(activeModelProvider)?.contextWindow ?? 0,
                // 舞台上下都是空白：垂直边距交给舞台算，面板才真正居中。
                padding: const EdgeInsets.symmetric(horizontal: 16),
                safeBottom: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
