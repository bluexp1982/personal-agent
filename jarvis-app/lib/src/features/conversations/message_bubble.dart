import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/design/message_palette.dart';
import '../../core/models.dart';
import '../memory/memory_navigation.dart';
import 'activity_timeline.dart';
import 'file_artifact_card.dart';
import 'media_artifact_card.dart';
import 'message_attachments.dart';
import 'message_copy_button.dart';
import 'message_markdown.dart';
import 'suggestion_card.dart';

/// 用户气泡的最大宽度。
///
/// 约为内容列（720）的七成：参考图里用户发言是一小块"便签"，占满整列会让
/// 右侧显得很重，也失去与助手整宽排版的对比。
const double kUserBubbleMaxWidth = 500;

/// 产物卡片的最小槽宽：再窄两张并排就放不下文件路径与按钮了。
const double _outputCardMinWidth = 320;

/// 产物卡片之间的间距，两列时也是列距。
const double _outputCardGap = 10;

/// 聊天气泡：决定"谁走哪条渲染路径"，以及气泡本身的外观。
///
/// 两条路径刻意长成两个样子：
/// - 用户发言是一小块浅色气泡，下面挂时间与复制；
/// - 助手回答像一篇文档——状态行、分割线、正文、元信息行，不套背景卡片。
///
/// 抽成独立公开组件是为了能被 widget 测试直接驱动——`chat_page` 里的
/// 私有组件没法在测试里构造。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.dispatchStates,
    this.suggestionTasks = const <String, TaskView>{},
    required this.onDispatch,
    this.onOpenTask,
    this.onDecideFileWrite,
    this.onOpenFileWrite,
    this.onSaveFileWrite,
    this.onOpenMedia,
    this.fileWriteBusy = const <String>{},
    this.conversationTitle = '',
    this.canSaveMediaToProject = true,
  });

  final ChatMessage message;
  final Map<String, String> dispatchStates;

  /// `消息id:技能` → 已派出去的任务。空表示还没派过。
  final Map<String, TaskView> suggestionTasks;

  final void Function(TaskSuggestion suggestion) onDispatch;
  final ValueChanged<String>? onOpenTask;

  /// 覆盖决策：`approve=false` 表示取消。
  final void Function(FileWriteView write, bool approve)? onDecideFileWrite;

  /// 打开生成的文件（落点与类型是否可预览由页面决定）。
  final void Function(FileWriteView write)? onOpenFileWrite;

  /// 把生成的文件另存到本机。
  final void Function(FileWriteView write)? onSaveFileWrite;

  /// 打开图片 / 视频产物的预览。
  final void Function(MediaAsset asset)? onOpenMedia;

  /// 正在等决策结果的请求 id：按钮置灰，避免连点。
  final Set<String> fileWriteBusy;

  /// 会话标题：媒体产物「另存为」的自动名要用它（`标题_工具_时间戳`）。
  final String conversationTitle;

  /// 会话是否归属项目：决定产物卡片上「保存到项目」是否可选。
  final bool canSaveMediaToProject;

  @override
  Widget build(BuildContext context) {
    if (message.isUser) {
      return _UserMessage(message: message);
    }
    // 系统提示（目前只有「已记住：…」）：居中、无气泡，与两条对话气泡区分开。
    if (message.role == 'system') {
      return _SystemNotice(message: message);
    }
    return _AssistantMessage(
      message: message,
      dispatchStates: dispatchStates,
      suggestionTasks: suggestionTasks,
      onDispatch: onDispatch,
      onOpenTask: onOpenTask,
      onDecideFileWrite: onDecideFileWrite,
      onOpenFileWrite: onOpenFileWrite,
      onSaveFileWrite: onSaveFileWrite,
      onOpenMedia: onOpenMedia,
      fileWriteBusy: fileWriteBusy,
      conversationTitle: conversationTitle,
      canSaveMediaToProject: canSaveMediaToProject,
    );
  }
}

/// 系统提示：居中小字，不套气泡、不带时间与复制按钮。
///
/// 它是"系统说的一句话"，不是对话的一轮：给气泡会让人以为助手又答了一句，
/// 给复制按钮又会让它看起来像可引用的内容。
class _SystemNotice extends StatelessWidget {
  const _SystemNotice({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            message.content,
            textAlign: TextAlign.center,
            style: text.meta.copyWith(color: palette.text.tertiary),
          ),
        ),
      ),
    );
  }
}

/// 用户消息：右对齐气泡 + 一行"时间 / 复制"。
class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).message;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: palette.userText,
      height: AppLineHeight.normal,
      fontSize: AppFontSize.base,
    );
    final metaStyle = _metaStyle(context, palette);

    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Container(
            constraints: const BoxConstraints(maxWidth: kUserBubbleMaxWidth),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: palette.userBubble,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 只发附件不写文字时不留一句省略号：那会让人以为话没打完。
                if (message.content.isNotEmpty)
                  SelectableText(message.content, style: textStyle)
                else if (message.attachments.isEmpty)
                  SelectableText('…', style: textStyle),
                if (message.attachments.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: message.content.isEmpty ? 0 : 8,
                    ),
                    // 芯片用与输入框同一套外观：用户能一眼认出"这就是我刚附的那几枚"。
                    child: MessageAttachmentChips(
                      attachments: message.attachments,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (message.createdAt > 0)
                Text(formatMessageTime(message.createdAt), style: metaStyle),
              const SizedBox(width: 8),
              MessageCopyButton(text: message.content),
            ],
          ),
        ],
      ),
    );
  }
}

/// 助手回答：状态行 → 分割线 → 正文 → 元信息行。
class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.message,
    required this.dispatchStates,
    required this.suggestionTasks,
    required this.onDispatch,
    required this.onOpenTask,
    required this.onDecideFileWrite,
    required this.onOpenFileWrite,
    required this.onSaveFileWrite,
    required this.onOpenMedia,
    required this.fileWriteBusy,
    required this.conversationTitle,
    required this.canSaveMediaToProject,
  });

  final ChatMessage message;
  final Map<String, String> dispatchStates;
  final Map<String, TaskView> suggestionTasks;
  final void Function(TaskSuggestion suggestion) onDispatch;
  final ValueChanged<String>? onOpenTask;
  final void Function(FileWriteView write, bool approve)? onDecideFileWrite;
  final void Function(FileWriteView write)? onOpenFileWrite;
  final void Function(FileWriteView write)? onSaveFileWrite;
  final void Function(MediaAsset asset)? onOpenMedia;
  final Set<String> fileWriteBusy;
  final String conversationTitle;
  final bool canSaveMediaToProject;

  /// 首行文案：状态 + 用时。丢掉的半截回答说"失败"，别假装已完成。
  ///
  /// 「已停止」单列一档：内容是用户自己喊停截断的，既不是失败也不是写完，
  /// 说"失败"会让人以为要重试。
  String get _statusLabel {
    if (message.streaming) {
      return '生成中…';
    }
    final base = message.failed
        ? '生成失败'
        : message.stopped
        ? '已停止'
        : '已完成';
    if (message.elapsedMs <= 0) {
      return base;
    }
    return '$base，用时 ${formatElapsed(message.elapsedMs)}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).message;
    final scheme = Theme.of(context).colorScheme;
    final metaStyle = _metaStyle(context, palette);
    final bodyStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: scheme.onSurface,
      height: AppLineHeight.relaxed,
      fontSize: AppFontSize.base,
    );

    // 媒体与生成文件都是"这一轮的产出"，放在同一个网格里排：
    // 一段视频加一个文件也能并排，不必按类型各占一段。
    final outputs = <Widget>[
      for (final asset in message.media)
        MediaArtifactCard(
          asset: asset,
          conversationTitle: conversationTitle,
          canSaveToProject: canSaveMediaToProject,
          onOpen: onOpenMedia,
        ),
      for (final write in message.fileWrites)
        FileWriteArtifactCard(
          write: write,
          busy: fileWriteBusy.contains(write.requestId),
          onDecide: onDecideFileWrite,
          onOpen: onOpenFileWrite,
          onSave: onSaveFileWrite == null
              ? null
              : () => onSaveFileWrite!(write),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              _statusLabel,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: AppFontSize.md,
                height: AppLineHeight.tight,
                color: message.failed ? scheme.error : palette.meta,
              ),
            ),
            if (message.streaming) ...<Widget>[
              const SizedBox(width: 6),
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: palette.meta,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Divider(height: 1, thickness: 1, color: palette.divider),
        const SizedBox(height: 12),
        // 执行过程放在正文之前：它是"怎么得到这个回答"的过程。
        // 折叠状态下只占一行，不会把回答挤下去。
        if (message.steps.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ActivityTimeline(
              steps: message.steps,
              streaming: message.streaming,
            ),
          ),
        if (message.content.isEmpty)
          // 有执行过程时不再叠一个省略号：两处占位只会让人以为卡住了。
          message.steps.isEmpty
              ? Text('…', style: bodyStyle)
              : const SizedBox.shrink()
        else
          MessageMarkdown(data: message.content),
        // 产物卡片紧跟正文：它们是这一轮最直接的产出，不该排在其他卡片后面。
        // 宽时两列并排、窄时整行，单张也只占一列（见 [_OutputCards]）。
        if (outputs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _OutputCards(children: outputs),
          ),
        if (message.suggestions.isNotEmpty)
          for (final suggestion in message.suggestions)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SuggestionCard(
                suggestion: suggestion,
                state: dispatchStates['${message.id}:${suggestion.skill}'],
                task: suggestionTasks['${message.id}:${suggestion.skill}'],
                onTap: () => onDispatch(suggestion),
                onOpenTask: onOpenTask,
              ),
            ),
        if (message.sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SourceChips(sources: message.sources),
          ),
        // 还在写的时候不给元信息行：复制半截回答没有意义，
        // 用时/用量也要等收尾才知道。
        if (!message.streaming) ...<Widget>[
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              MessageCopyButton(text: message.content),
              if (message.usage != null) ...<Widget>[
                const SizedBox(width: 10),
                Text(formatTokenUsage(message.usage!), style: metaStyle),
              ],
              if (message.createdAt > 0) ...<Widget>[
                const SizedBox(width: 10),
                Text(formatMessageTime(message.createdAt), style: metaStyle),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// 产物卡片的排布：宽度够时两列，不够时整行。
///
/// 用 `Wrap` 而不是网格：卡片高度本来就不一样（文件卡可能多一行备份路径，
/// 视频卡多一段描述），按行顶部对齐、各自保持固有高度即可；固定
/// `mainAxisExtent` 的 `GridView` 会裁内容，`IntrinsicHeight` 又会把矮卡拉高。
///
/// 单张也按一列的槽宽摆：与两列时一致，之后多出一张时已有卡片不会突然变宽。
class _OutputCards extends StatelessWidget {
  const _OutputCards({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        // 宽度无界时不猜比例，老老实实竖着排。
        if (!available.isFinite || available <= 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          );
        }

        final twoUp = available >= _outputCardMinWidth * 2 + _outputCardGap;
        final slot = twoUp ? (available - _outputCardGap) / 2 : available;

        return Wrap(
          spacing: _outputCardGap,
          runSpacing: _outputCardGap,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            for (final child in children) SizedBox(width: slot, child: child),
          ],
        );
      },
    );
  }
}

/// 元信息文字：小号、低对比，不与正文抢注意力。
TextStyle? _metaStyle(BuildContext context, MessagePalette palette) {
  return Theme.of(context).textTheme.labelSmall?.copyWith(
    fontSize: AppFontSize.sm,
    height: AppLineHeight.tight,
    color: palette.meta,
  );
}

/// 消息时间：`9月25日 16:34`。
///
/// 带月日而不是只有时分：往上翻历史时"几点"没有意义，"哪天"才有。
String formatMessageTime(int milliseconds) {
  if (milliseconds <= 0) {
    return '';
  }
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.month}月${time.day}日 ${two(time.hour)}:${two(time.minute)}';
}

/// 耗时：`32 秒` / `1 分 58 秒`，精确到秒。
String formatElapsed(int milliseconds) {
  final seconds = (milliseconds / 1000).round();
  if (seconds < 60) {
    return '${seconds < 0 ? 0 : seconds} 秒';
  }
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  if (rest == 0) {
    return '$minutes 分';
  }
  return '$minutes 分 $rest 秒';
}

/// 用量：`856 tokens` / `1.2k tokens`；估算值前面加"约"。
///
/// 单位写全而不是 `tok`：这不是有上下文可猜的图表轴标签，读者第一眼
/// 要能认出这是"token 数"，省两个字符换来一次困惑不划算。
String formatTokenUsage(TokenUsage usage) {
  final prefix = usage.estimated ? '≈' : '';
  return '$prefix${compactCount(usage.total)} tokens';
}

/// 把计数压成 `1.2k` / `29.2M` 这种短形式：元信息行放不下六位数字。
String compactCount(int value) {
  if (value < 1000) {
    return '$value';
  }
  if (value < 1000000) {
    return '${_trimZero(value / 1000)}k';
  }
  return '${_trimZero(value / 1000000)}M';
}

String _trimZero(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// 来源卡片：一行浅色标签，与气泡同宽、可换行。
///
/// 三类来源长成三个样子：
/// - `web`：域名 + 采集时间，点击复制链接；
/// - `memory`：`来自记忆`，点击进记忆详情；没有 `memory_id` 时不可点；
/// - `doc`：项目相对路径 + 采集时间，点击复制路径（`read_file` / `search_content` 产生）。
///
/// 记忆来源会被折叠：常驻摘要每轮都可能命中同一批偏好，
/// 不折叠的话来源区会变成一面墙，把回答挤下去。
class SourceChips extends StatefulWidget {
  const SourceChips({super.key, required this.sources});

  final List<MessageSource> sources;

  /// 折叠阈值：超过这么多条记忆来源就收起。
  static const int collapsedMemoryLimit = 3;

  @override
  State<SourceChips> createState() => _SourceChipsState();
}

class _SourceChipsState extends State<SourceChips> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final memories = widget.sources.where((source) => source.isMemory).toList();
    final others = widget.sources.where((source) => !source.isMemory).toList();

    final visibleMemories = _expanded
        ? memories
        : memories.take(SourceChips.collapsedMemoryLimit).toList();
    final hidden = memories.length - visibleMemories.length;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final source in others) _chip(context, source),
        for (final source in visibleMemories) _chip(context, source),
        if (hidden > 0)
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () => setState(() => _expanded = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Text('+$hidden 条记忆', style: AppText.of(context).meta),
            ),
          ),
      ],
    );
  }

  Widget _chip(BuildContext context, MessageSource source) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final canTap = !source.isMemory || source.canOpen;

    final label = switch (source.kind) {
      MessageSourceKind.memory => '来自记忆 · ${formatFetchedAt(source.fetchedAt)}',
      MessageSourceKind.doc => '${source.host} · ${formatFetchedAt(source.fetchedAt)}',
      MessageSourceKind.web => '${source.host} · ${formatFetchedAt(source.fetchedAt)}',
    };
    final icon = switch (source.kind) {
      MessageSourceKind.memory => Icons.psychology_outlined,
      MessageSourceKind.doc => Icons.description_outlined,
      MessageSourceKind.web => Icons.link,
    };

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: palette.text.tertiary),
          const SizedBox(width: 4),
          // 记忆卡片文字用主色：它是"回答凭什么这么说"的依据，比网页域名更重要。
          Text(
            label,
            style: source.isMemory
                ? text.meta.copyWith(color: palette.text.secondary)
                : text.meta,
          ),
        ],
      ),
    );

    if (!canTap) {
      // 没有 memory_id 的记忆来源降级为纯文本：点了没反应比不能点更糟。
      return chip;
    }

    return Tooltip(
      message: switch (source.kind) {
        MessageSourceKind.memory => '查看这条记忆',
        MessageSourceKind.doc => '复制路径：${source.host}',
        MessageSourceKind.web => source.url,
      },
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: () => _onTap(context, source),
        child: chip,
      ),
    );
  }

  Future<void> _onTap(BuildContext context, MessageSource source) async {
    switch (source.kind) {
      case MessageSourceKind.memory:
        final id = source.memoryId ?? '';
        if (id.isNotEmpty) {
          await openMemoryDetail(context, id);
        }
      case MessageSourceKind.doc:
        // 本地文件没有"打开"的通用出口（各平台协议不同），复制路径最实用：
        // 用户可以直接粘进编辑器或终端。
        final path = source.host;
        await Clipboard.setData(ClipboardData(text: path));
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('已复制路径：$path'),
            duration: const Duration(seconds: 2),
          ),
        );
      case MessageSourceKind.web:
        await Clipboard.setData(ClipboardData(text: source.url));
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('链接已复制'),
            duration: Duration(seconds: 2),
          ),
        );
    }
  }
}

/// 采集时间按本地时区显示成 `MM-dd HH:mm`：卡片上只要够判断"新鲜度"。
String formatFetchedAt(int milliseconds) {
  if (milliseconds <= 0) {
    return '时间未知';
  }
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}
