import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/code_providers.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/artifact_naming.dart';
import '../../core/client_platform.dart';
import '../../core/model_providers.dart';
import '../../core/models.dart';
import '../../core/preview_source.dart';
import '../../core/session.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/rename_dialog.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/chat_float_icon.dart';
import '../shell/chat_window_state.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/file_pane_state.dart';
import '../preview/preview_actions.dart';
import '../shell/pane_surface.dart';
import '../shell/preview_launcher.dart';
import '../shell/selection_toolbar.dart';
import '../shell/shell_dividers.dart';
import '../shell/shell_layout_state.dart';
import '../tasks/code_task_input_dialog.dart';
import '../tasks/task_detail_page.dart';
import 'approval_mode.dart';
import 'chat_composer_area.dart';
import 'compaction_bar.dart';
import 'compaction_dialog.dart';
import 'composer_reasoning.dart';
import 'composer_text.dart';
import 'message_body.dart';
import 'message_bubble.dart';
import 'new_session_stage.dart';
import 'pending_chat_message.dart';
import 'task_state_card.dart';

// 时间格式化跟着气泡组件搬走了，但历史调用方（测试）还从这里取。
export 'message_bubble.dart' show formatFetchedAt;

// 输入面板的常量也跟着组件搬去了 `chat_composer.dart`，这里继续对外暴露。
export 'chat_composer.dart' show kChatComposerMinHeight;

// 内容栏限宽跟着输入区外框搬去了 `chat_composer_area.dart`，同样继续对外暴露。
export 'chat_composer_area.dart' show kChatColumnMaxWidth;

/// 流式增量的合并间隔：Markdown 每刷新一次都要整段重解析，
/// 攒到 80ms 一次（约 12 帧/秒）肉眼仍是连续增长，但解析次数降一个量级。
const Duration streamFlushInterval = Duration(milliseconds: 80);

/// 点了停止之后等服务端收尾的上限。
///
/// 正常情况服务端一个 token 的间隔内就会把 `message_completed(stopped)` 推回来；
/// 定一个上限是为了兜住"旧版本服务端没有停止接口""请求卡在网络上"这类情况——
/// 界面不能因为对面没反应就一直停在"生成中"。
const Duration stopFallbackDelay = Duration(seconds: 3);

/// "回到底部"浮标的 key。
///
/// 浮标始终在树里、靠透明度显隐（淡入淡出），测试据此断言状态，
/// 而不是依赖某个图标名字。
const Key jumpToBottomKey = ValueKey<String>('chat-jump-to-bottom');

/// 服务端新建会话的占位标题，与 `conversation::DEFAULT_TITLE` 对应。
///
/// 标题生成是异步的：回答结束时若还是这个值，说明服务端还没写完，值得再等一拍。
const String defaultConversationTitle = '新会话';

/// 聊天窗口当前以什么形态示人。
///
/// 三种形态共用同一份 State（消息、流、滚动、草稿），区别只在栏头与容器：
/// - [page]：窄屏从列表点进来的整页路由，带自己的 AppBar；
/// - [docked]：宽屏停靠在中栏，栏头用 [EmbeddedToolbar]；
/// - [floating]：缩成可拖动的小窗，栏头只有标题与三枚按钮。
///
/// 形态变化**不允许**改变 `build()` 里的节点结构：见 `_body` 的槽位注释。
enum ChatPresentation { page, docked, floating }

/// 单会话：历史 + 流式回答。
///
/// 发送后服务端以 SSE 返回 `message_delta` / `message_completed`；
/// 收到 `message_completed` 时消息已落库，退出重进能查到。
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    required this.conversationId,
    required this.title,
    this.projectPath,
    this.projectId = '',
    this.canSaveMediaToProject = true,
    this.presentation = ChatPresentation.page,
    this.onOpenTask,
    this.onClose,
    this.onBack,
    this.onRenamed,
    this.onDeleted,
    this.onFloat,
    this.onDock,
    this.onCloseWindow,
  });

  final String conversationId;
  final String title;

  /// 会话所属项目的目录。编码任务对话框只读展示它，标清"改的是哪儿"。
  final String? projectPath;

  /// 会话所属项目 id。
  ///
  /// 产物卡片的「打开」统一落到右栏预览标签，而右栏取字节要项目 id：
  /// 窄屏整页形态下 `shellProjectMemoProvider` 未必是会话那个项目，
  /// 所以由页面显式带下来。
  final String projectId;

  /// 会话是否归属项目：媒体产物卡片据此决定「保存到项目」能不能选。
  ///
  /// 只是入口层的提示，真正的准入在服务端（它会反查产物归属项目）；
  /// 从"未归属会话"列表进来时传 false，避免给一个必然失败的选项。
  final bool canSaveMediaToProject;

  /// 当前形态。默认整页：窄屏路由与直接构造的测试都走这一条。
  final ChatPresentation presentation;

  /// 派任务成功后怎么打开任务详情。
  ///
  /// 宽屏下由外壳把它接到"右侧原地切换"，不传时退回整页 push。
  final ValueChanged<String>? onOpenTask;

  /// 「关闭」时怎么收尾。宽屏下由外壳切回所属项目；不传就等同于返回上一页。
  final VoidCallback? onClose;

  /// 整页形态的返回箭头怎么收尾。
  ///
  /// 正常路由推上来的会话页不传，走默认的 `Navigator.maybePop`；
  /// 窄屏浮窗层铺满整窗时也没有路由可退，由外壳传"收起这一屏"。
  final VoidCallback? onBack;

  /// 标题改掉之后通知外层：侧栏会话列表与右侧标题要一起换。
  final ValueChanged<String>? onRenamed;

  /// 删除成功之后通知外层：列表要刷新，右侧也不能继续显示一个已经不存在的会话。
  final VoidCallback? onDeleted;

  /// 停靠态栏头「缩小为浮窗」。
  ///
  /// 由外壳（`ChatWindowLayer`）闭包住当前会话：它才知道要把哪一份冻进浮窗。
  /// 不传时按钮不出现——整页形态没有"缩到哪儿"这回事。
  final VoidCallback? onFloat;

  /// 浮窗栏头「停靠回中栏」。
  final VoidCallback? onDock;

  /// 浮窗栏头「关闭小窗」。
  ///
  /// 与 [onClose] 分开：那个是"关闭会话"（要回项目、刷列表），
  /// 这一个只是让浮窗消失，中栏原本显示什么继续显示什么。
  final VoidCallback? onCloseWindow;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// 富文本输入控制器：技能标签是文档里的一个节点。
  ///
  /// 读写一律走 `composer_text.dart` 的助手，不要直接拼 `Document`——
  /// 那里面要处理 embed 占位符、末尾换行与"只有一个技能标签"的约束。
  final QuillController _input = QuillController.basic();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = <ChatMessage>[];

  bool _loading = true;
  bool _sending = false;
  String? _error;
  int? _streamingIndex;
  StreamSubscription<Map<String, dynamic>>? _stream;

  /// 这个会话的上下文压缩状态。null = 从未压缩过（或服务端关掉了压缩）。
  CompactionView? _compaction;

  /// 正在请求"重新整理"：按钮置灰，避免连点压出两次。
  bool _compactionBusy = false;

  /// 回答结束后补读一次详情用的定时器。
  ///
  /// 用可取消的 `Timer` 而不是 `Future.delayed`：页面被关掉时未触发的延迟
  /// 会留在测试的定时器队列里（"A Timer is still pending"），而这只是
  /// 一次"看看摘要写完没有"的补读，没必要绑着页面生命周期。
  Timer? _detailRefreshTimer;

  /// 本轮回答的身份（发送时带的 `client_msg_id`）：停止接口靠它寻址。
  String? _activeClientMessageId;

  /// 已经点了停止、正等服务端收尾。
  ///
  /// 它同时决定收尾时怎么标这条消息：`true` 标"已停止"，否则按断流标失败。
  bool _stopping = false;

  /// 等流结束的闸门。
  ///
  /// 换成 `listen` + `Completer` 而不是 `await for`，是因为停止必须能从外面
  /// 取消订阅；`await for` 的订阅拿不到句柄，只能等它自己走完。
  Completer<void>? _streamDone;

  /// 停止的兜底定时器；正常收尾时必须取消，否则会在收尾之后又触发一次。
  Timer? _stopFallback;

  /// 列表是否贴在底部。
  ///
  /// 两处用它：流式输出只在贴底时自动跟随（否则用户往上翻历史会被拽回来），
  /// 以及决定要不要浮出"回到底部"按钮。
  bool _atBottom = true;

  /// 判"贴底"的容差：留一点余量，动画收尾与像素取整都不会让按钮闪一下。
  static const double _bottomTolerance = 24;

  /// 跟随滚动时允许的最长动画距离。
  ///
  /// 超过这个跨度就直接 `jumpTo`：几百像素的 `animateTo` 会一路"追"过去，
  /// 期间弹性物理还在清算越界位置，两股动画叠在一起看着就是列表在抽动。
  static const double _maxAnimatedScroll = 240;

  /// 上一次布局的最大滚动距离。
  ///
  /// 内容变矮（图片占位换成成品、执行过程收起、建议卡消失）会让这个值变小，
  /// 而 `BouncingScrollPhysics` 不夹紧旧的像素偏移——贴底的列表因此被"顶出"
  /// 底部之外，再花一秒弹回来。记下旧值就是为了在这种时候一次性钉回底部。
  double? _lastMaxExtent;

  /// 建议卡的按钮状态：`消息id:技能` → creating / created / failed。

  /// 本会话通过 `@技能` 派出的任务：渲染在消息流末尾，随执行推进。
  ///
  /// 不落成消息——落消息要调 `/messages`，会白烧一次模型调用并产生一条假对话。
  /// 重进会话时按幂等键前缀从 `/api/tasks` 恢复。
  final List<AtTaskView> _atTasks = <AtTaskView>[];

  final Map<String, String> _dispatchStates = <String, String>{};

  /// 正在等覆盖决策结果的请求 id：卡片按钮据此置灰，避免连点写出两次。
  final Set<String> _fileWriteBusy = <String>{};

  /// 覆盖确认事件比 `message_completed` 早到：先攒着，收尾时与消息里的
  /// `file_writes` 合并（服务端那份是权威，同 id 以它为准）。
  final Map<String, FileWriteView> _pendingFileWrites = <String, FileWriteView>{};

  /// 流式期间累积的执行过程。
  ///
  /// 同一次工具调用会推两帧（`running` 与 `ok`/`failed`），按 `call_id`
  /// 更新同一行而不是追加——否则一次读文件在界面上会变成两行。
  /// 收尾时用 `message_completed.steps` 覆盖（服务端那份含最终耗时）。
  final List<ChatStep> _streamSteps = <ChatStep>[];

  /// `消息id:技能` → 已派出去的任务。
  ///
  /// 由 `_refreshSuggestionTasks` 按幂等键从任务列表里匹配出来：卡片据此显示
  /// 实时状态，并把"再派一次"换成"查看任务"。
  final Map<String, TaskView> _suggestionTasks = <String, TaskView>{};

  /// 建议卡的任务轮询。只在"有建议且还没全部结束"时跑，全部终态就停。
  Timer? _suggestionPoll;

  /// AppBar 标题：进入时用列表给的那份，回答结束后按服务端生成的标题刷新。
  late String _title;

  /// 菜单里的异步动作（重命名 / 删除）正在跑：把「…」换成小 spinner，
  /// 既防重复提交，也让"点了没反应"有个交代。
  bool _busy = false;

  /// 流式增量先攒起来，每 [streamFlushInterval] 合并一次 setState。
  ///
  /// 回答是 Markdown，每来一个增量都要把整段重新解析一遍；按 token 频率
  /// 重解析会让滚动条发飘。合并到 12 次/秒，肉眼仍是连续增长。
  final StringBuffer _deltaBuffer = StringBuffer();
  Timer? _deltaTimer;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _scroll.addListener(_handleScroll);
    // 历史加载完之后再发空态页交接过来的第一句，顺序不能反（见 `_maybeSendPending`）。
    unawaited(_loadHistory().then((_) => _maybeSendPending()));
    unawaited(_refreshDetail());
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.presentation != widget.presentation) {
      // 形态切换会改这块区域的宽高（中栏 → 小窗），「贴底」是拿最大滚动距离
      // 判的，尺寸一变这个值就作废了。帧后滚一次：那时新尺寸已经布局完成，
      // 滚到的才是真正的底部。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToBottom();
        }
      });
    }
  }

  @override
  void dispose() {
    _deltaTimer?.cancel();
    _stopFallback?.cancel();
    _suggestionPoll?.cancel();
    _detailRefreshTimer?.cancel();
    unawaited(_stream?.cancel());
    _scroll.removeListener(_handleScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 只在"贴底 ⇄ 离开底部"跨过阈值时重建，不逐像素刷新界面。
  void _handleScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final atBottom =
        position.maxScrollExtent - position.pixels <= _bottomTolerance;
    if (atBottom != _atBottom) {
      setState(() => _atBottom = atBottom);
    }
  }

  /// 内容高度变化后的收尾：变矮且原本贴底就钉回底部。
  ///
  /// 两条路径都会让 `maxScrollExtent` 变小：媒体卡片从占位换成成品、执行过程
  /// 收起、建议卡被派成任务。此时像素偏移还停在旧值上，列表就悬在内容之外，
  /// 之后由弹性物理慢慢弹回来——用户看到的是"页面一直在抽动"。
  /// 用户已经往上翻历史时保持原位，与流式跟随的口径一致（不把人拽回底部）。
  bool _handleScrollMetrics(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;
    final previous = _lastMaxExtent;
    _lastMaxExtent = metrics.maxScrollExtent;

    if (previous == null || metrics.maxScrollExtent >= previous - 0.5) {
      return false;
    }
    if (previous - metrics.pixels > _bottomTolerance) {
      return false;
    }
    // 通知是帧后的微任务，此刻布局已结束：直接改像素，不必再等一帧。
    if (_scroll.hasClients) {
      _scroll.position.jumpTo(metrics.maxScrollExtent);
      _lastMaxExtent = metrics.maxScrollExtent;
    }
    return false;
  }

  Future<void> _loadHistory() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    try {
      final page = await client.getJson(
        '/api/conversations/${widget.conversationId}/messages',
        query: <String, String>{'limit': '50'},
      );
      final items = page['items'] as List<dynamic>? ?? const <dynamic>[];
      final parsed = items
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList();

      // 服务端按时间倒序返回，界面要正序。
      if (!mounted) {
        return;
      }
      setState(() {
        _messages
          ..clear()
          ..addAll(parsed.reversed);
        // 历史是权威：暂存表只装"本轮还没收尾的待确认卡"，重载后一句都不该留。
        _pendingFileWrites.clear();
        _loading = false;
      });
      _syncSuggestionPolling();
      _jumpToBottom();
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

  /// 发掉空态页交接过来的第一句话。
  ///
  /// 必须等历史加载完成：`_loadHistory` 会 `_messages.clear()`，先发的话
  /// 乐观气泡与流式占位会被冲掉，`_streamingIndex` 也会指向一条不存在的消息。
  /// 只在客户端可用时才取走——取走即清空，没连上时白白丢一句话。
  Future<void> _maybeSendPending() async {
    if (!mounted || ref.read(apiClientProvider) == null) {
      return;
    }
    final pending = ref
        .read(pendingChatMessageProvider.notifier)
        .take(widget.conversationId);
    if (pending == null) {
      return;
    }

    // 空态页选好的技能跟着一起过来：直接派任务，不必把标签重新插回文档
    // （那要多写一遍"构造 embed"的代码，还容易和文档里的约束对不上）。
    final skill = pending.skill;
    if (skill != null) {
      await _dispatchAtSkill(skill, pending.text);
      return;
    }

    setComposerText(_input, pending.text);
    // 附件必须一起还原：芯片本身就是"发了什么"的唯一凭据，
    // 只交文本等于把用户附的文件静默丢掉。
    for (final embed in pending.attachments) {
      insertAttachmentEmbed(_input, embed);
    }
    await _send();
  }

  /// 建议卡在本地状态表里的键。
  String _suggestionKey(String messageId, String skill) => '$messageId:$skill';

  /// 是否还有建议卡"没派出去"或"任务没结束"。
  ///
  /// 已完成/失败/取消的任务不会再变，没必要继续轮询。
  bool get _hasLiveSuggestion {
    for (final message in _messages) {
      for (final suggestion in message.suggestions) {
        final task =
            _suggestionTasks[_suggestionKey(message.id, suggestion.skill)];
        if (task == null || !task.isTerminal) {
          return true;
        }
      }
    }
    return false;
  }

  /// 是否还有 `@` 派出的任务在跑（或还没建完）。
  bool get _hasLiveAtTask => _atTasks.any(
    (entry) => entry.state != 'created' || !(entry.task?.isTerminal ?? false),
  );

  /// 按需启动/停止任务轮询。
  ///
  /// 建议卡与 `@` 任务共用同一个定时器：它们拉的是同一个列表，
  /// 各起一个只会让同一秒里发两次一样的请求。
  void _syncSuggestionPolling() {
    final live = _hasLiveSuggestion || _hasLiveAtTask;
    if (!live) {
      _suggestionPoll?.cancel();
      _suggestionPoll = null;
      // 仍然补拉一次：刚进会话时 `@` 任务还没恢复出来。
      unawaited(_refreshSuggestionTasks());
      return;
    }
    _suggestionPoll ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshSuggestionTasks()),
    );
    unawaited(_refreshSuggestionTasks());
  }

  /// 拉一次本会话的任务：按幂等键挂到建议卡与 `@` 任务卡上。
  ///
  /// 两种幂等键前缀：
  /// - `conv:<会话>:msg:<消息>:skill:<技能>` —— 建议卡派出的；
  /// - `at:<会话>:<时间戳>:<技能>` —— 会话里 `@` 派出的。
  Future<void> _refreshSuggestionTasks() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    try {
      final page = await client.getJson(
        '/api/tasks',
        query: <String, String>{
          'conversation_id': widget.conversationId,
          'limit': '100',
        },
      );
      if (!mounted) {
        return;
      }

      final prefix = 'conv:${widget.conversationId}:msg:';
      final byKey = <String, TaskView>{};
      final items = page['items'] as List<dynamic>? ?? const <dynamic>[];
      for (final raw in items.whereType<Map<String, dynamic>>()) {
        final task = TaskView.fromJson(raw);
        final key = task.idempotencyKey;
        if (key == null || !key.startsWith(prefix)) {
          continue;
        }
        final rest = key.substring(prefix.length);
        final split = rest.lastIndexOf(':skill:');
        if (split <= 0) {
          continue;
        }
        byKey['${rest.substring(0, split)}:${rest.substring(split + 7)}'] =
            task;
      }

      _syncAtTasks(items);

      // 状态没变就不重建：2 秒一次的无差别 setState 会让长列表白刷。
      final changed =
          byKey.length != _suggestionTasks.length ||
          byKey.entries.any((entry) {
            final current = _suggestionTasks[entry.key];
            return current == null ||
                current.id != entry.value.id ||
                current.state != entry.value.state;
          });
      if (changed) {
        setState(() {
          _suggestionTasks
            ..clear()
            ..addAll(byKey);
        });
      }
      if (!_hasLiveSuggestion) {
        _suggestionPoll?.cancel();
        _suggestionPoll = null;
      }
    } on ApiException {
      // 状态是附加信息：拉不到就保持上一次，不打断正在看的回答。
    }
  }

  /// 把 `@` 派出的任务与本地卡片对齐：补齐恢复出来的、刷新已有的状态。
  ///
  /// 幂等键前缀 `at:<会话>:<时间戳>:<技能>`，本地已有的按 task id 认，不重建，
  /// 否则每 2 秒轮询一次卡片都会闪一下。
  void _syncAtTasks(List<dynamic> items) {
    final prefix = 'at:${widget.conversationId}:';
    final latest = <String, TaskView>{};

    for (final raw in items.whereType<Map<String, dynamic>>()) {
      final task = TaskView.fromJson(raw);
      final key = task.idempotencyKey;
      if (key == null || !key.startsWith(prefix)) {
        continue;
      }
      latest[task.id] = task;
    }

    var touched = false;

    // 已渲染的卡片跟着状态走。
    for (final entry in _atTasks) {
      final id = entry.task?.id;
      if (id == null) {
        continue;
      }
      final fresh = latest[id];
      if (fresh != null && fresh.state != entry.task!.state) {
        entry.task = fresh;
        touched = true;
      }
    }

    // 还没渲染的（重进会话）：补上。按创建时间排序，位置稳定。
    final known = _atTasks
        .map((entry) => entry.task?.id)
        .whereType<String>()
        .toSet();
    final recovered = latest.values
        .where((task) => !known.contains(task.id))
        .map(
          (task) => AtTaskView(
            key: task.idempotencyKey ?? task.id,
            skill: task.skill ?? '',
          )..task = task,
        )
        .toList();

    if (recovered.isNotEmpty) {
      setState(() => _atTasks.addAll(recovered));
      touched = false;
    }
    if (touched) {
      setState(() {});
    }
  }

  /// 拉一次会话详情：换标题、更新压缩状态。
  ///
  /// 标题是服务端在首条提问后异步生成的，客户端只能"问一下有没有变"；
  /// 上下文摘要是回答落库后后台生成的，同理。拿不到不是错误——列表页返回时
  /// 还会再刷一次。
  ///
  /// 换掉本地标题之后必须走 [ChatPage.onRenamed] 报到外层：侧栏那份会话列表
  /// 是 `conversationsProvider` 的缓存，不 invalidate 就会一直停在「新会话」。
  Future<void> _refreshDetail() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    try {
      final detail = await client.getJson(
        '/api/conversations/${widget.conversationId}',
      );
      if (!mounted) {
        return;
      }
      // 压缩状态整体替换：服务端记录是权威，客户端不自己拼状态。
      final compaction = CompactionView.tryParse(detail['compaction']);
      setState(() => _compaction = compaction);

      final title = detail['title'] as String?;
      if (title == null || title.isEmpty || title == _title) {
        return;
      }
      setState(() => _title = title);
      widget.onRenamed?.call(title);
    } on ApiException {
      // 标题只是索引：拿不到就保持原样，不打扰正在看回答的人。
    }
  }

  /// 回答结束后同步标题与摘要。
  ///
  /// 摘要由后台任务生成：回答落库时它一般还没写完（要真调一次模型），
  /// 回读一次基本必然错过——压缩要 3~8 秒，而这里只有一次 1.5 秒后的补读。
  /// 所以改成有界轮询：每 2 秒看一次，一旦读到摘要就停；最多 6 次（12 秒），
  /// 超了就等用户下次发送或重进会话时再刷新。
  ///
  /// 用可取消的 `Timer` 而不是 `Future.delayed`：页面关掉时未触发的延迟
  /// 会留在测试的定时器队列里（"A Timer is still pending"）。
  Future<void> _syncTitleAfterAnswer() async {
    await _refreshDetail();
    _scheduleCompactionPoll(remaining: 6);
  }

  /// 有界轮询压缩状态。
  ///
  /// 只在"这个会话还没有任何压缩记录"时值得问：已经有摘要的会话，
  /// 后续变化由下一次发送触发，不必一直问。
  void _scheduleCompactionPoll({required int remaining}) {
    _detailRefreshTimer?.cancel();
    if (remaining <= 0 || !mounted || _compaction != null) {
      return;
    }
    _detailRefreshTimer = Timer(const Duration(seconds: 2), () async {
      if (!mounted) {
        return;
      }
      await _refreshDetail();
      if (!mounted) {
        return;
      }
      _scheduleCompactionPoll(remaining: remaining - 1);
    });
  }

  /// 打开摘要弹窗。
  ///
  /// 外壳走全站通用的 `AppDialog`（见 `showCompactionDialog`），这里只把
  /// 当前视图与「重新整理」交出去。界面不提供"关闭压缩"：关了之后服务端
  /// 不再下发压缩状态，入口会连弹窗一起消失，要关只能走接口。
  Future<void> _openCompactionDialog() async {
    final view = _compaction;
    if (view == null) {
      return;
    }
    await showCompactionDialog(
      context,
      view: view,
      busy: _compactionBusy,
      onRegenerate: _regenerateCompaction,
    );
  }

  /// 手动重新整理上下文。
  ///
  /// 服务端是"202 受理 + 后台跑"，所以这里要等到摘要真的变了为止；
  /// 20 × 500ms 是"等它一会儿"的量级，超时就先放下——用户可以再点一次。
  ///
  /// 返回回读后的最新视图：弹窗拿它原地刷新（成功换新摘要，失败带上新的
  /// 失败原因、保留旧摘要）。没有 client / 已在整理时返回当前值，让弹窗
  /// 保持原样而不是卡在"整理中"。
  Future<CompactionView?> _regenerateCompaction() async {
    final client = ref.read(apiClientProvider);
    if (client == null || _compactionBusy) {
      return _compaction;
    }
    final beforeUpdate = _compaction?.updatedAt;
    final beforeFailure = _compaction?.lastFailure?.at;

    setState(() => _compactionBusy = true);
    try {
      await client.postJson(
        '/api/conversations/${widget.conversationId}/compaction',
        const <String, dynamic>{},
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) {
          return _compaction;
        }
        await _refreshDetail();
        final current = _compaction;
        if (current == null) {
          continue;
        }
        if (current.updatedAt != beforeUpdate ||
            current.lastFailure?.at != beforeFailure) {
          return current;
        }
      }
      return _compaction;
    } on ApiException catch (error) {
      _toast(error.userMessage);
      return _compaction;
    } finally {
      if (mounted) {
        setState(() => _compactionBusy = false);
      }
    }
  }

  /// 关掉当前会话：只把"正在看"的这一页收起来，不删任何数据。
  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    // 整页形态（窄屏 push 上来的）没有外壳托底：等同于返回。
    Navigator.of(context).maybePop();
  }

  /// 重命名会话。
  ///
  /// 服务端只接受 trim 后非空、且不超过上限的标题，所以这里不做本地截断——
  /// 让服务端按同一套规则拒绝，提示原样带回来，省得两端各写一份字数逻辑。
  Future<void> _rename() async {
    final title = await showRenameDialog(
      context,
      title: '重命名会话',
      label: '标题',
      initialValue: _title,
    );

    final trimmed = title?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted || trimmed == _title) {
      return;
    }

    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    setState(() => _busy = true);
    try {
      final updated = await client.patchJson(
        '/api/conversations/${widget.conversationId}',
        <String, dynamic>{'title': trimmed},
      );
      if (!mounted) {
        return;
      }
      // 以服务端回读的标题为准：它才是列表与栏头接下来会显示的那份。
      final saved = updated['title'] as String? ?? trimmed;
      setState(() {
        _title = saved;
        _busy = false;
      });
      widget.onRenamed?.call(saved);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _toast(error.userMessage);
    }
  }

  /// 删除会话：会话下的消息一起软删，未结束的任务会让服务端返回 409。
  Future<void> _delete() async {
    final confirmed = await confirmDeleteDialog(
      context,
      title: '删除「$_title」？',
      message:
          '会话里的消息会一并删除，无法恢复。\n\n'
          '会话下的任务也会一起删除；如果还有未结束的任务，删除会失败——请先取消它。',
      count: 1,
    );
    if (!confirmed || !mounted) {
      return;
    }

    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    setState(() => _busy = true);
    try {
      await client.delete('/api/conversations/${widget.conversationId}');
      if (!mounted) {
        return;
      }
      // 宽屏由外壳刷新列表并切回项目；整页形态没有外壳，直接返回上一页。
      final onDeleted = widget.onDeleted;
      if (onDeleted != null) {
        onDeleted();
        return;
      }
      _close();
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _toast(error.userMessage);
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 整页形态的标题：图标 + 标题。
  ///
  /// 与内嵌态那条工具行用同一个符号：窄屏 push 上来时不能因为换了一种栏头
  /// 就丢掉"这是一段会话"的标识。
  Widget _titleRow(BuildContext context) {
    return Padding(
      // 只有一行文字时，返回钮与标题之间要补一点呼吸；不然标题会贴在
      // 返回钮右侧 4dp 处（`MobileAppBar` 的 leading 已经让到 54）。
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        _title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // 页头行标题按原型用 14 / w600，不是页面标题的 16 / w700。
        style: mobileTopBarRowTitleStyle(context),
      ),
    );
  }

  /// 栏头右侧的「…」的样式：与同一行其它栏头按钮同构
  /// （命中区 24 / 8dp 圆角方形 / 零内边距），不再单独放大一号。
  static final ButtonStyle _menuButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  /// 栏头右侧的「…」：关闭 / 重命名 /（分组线）删除会话。
  ///
  /// 与项目页那一套同款浮层：破坏性操作单独分组，动作在事件回调里做，
  /// 不跟着 build 走。
  Widget _buildMenu({bool mobile = false}) {
    if (_busy) {
      return SizedBox(
        width: mobile ? kMobileTopBarButtonSize : 30,
        height: mobile ? kMobileTopBarButtonSize : 30,
        child: const Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return AgentMenu<String>(
      width: AgentMenuStyle.panelMinWidth,
      // 菜单从触发器的左边缘往下展开（bottomStart）：锚在右端时按 bottomEnd
      // 会向左溢出，压住栏头标题与标签栏。
      alignment: AlignmentDirectional.bottomStart,
      alignmentOffset: const Offset(0, 4),
      // 触发器是自己带 onPressed 的 IconButton：点击交给它，组件只管开合状态。
      triggerHandlesTap: false,
      // 「缩小为浮窗」除了栏头那枚图标，这里也放一项：画中画图标不是人人
      // 都认得，摆在「…」里至少让"窗口能变小"这件事可被读到。
      // 整页形态没有 `onFloat`，这一项自然不出现。
      groups: <AgentMenuGroup<String>>[
        AgentMenuGroup<String>(
          items: <AgentMenuItem<String>>[
            if (widget.onFloat != null)
              AgentMenuItem<String>(
                value: 'float',
                label: '缩小为浮窗',
                icon: Icons.picture_in_picture_alt_outlined,
              ),
            AgentMenuItem<String>(
              value: 'close',
              label: '关闭',
              icon: Icons.close_rounded,
            ),
            AgentMenuItem<String>(
              value: 'rename',
              label: '重命名',
              icon: Icons.drive_file_rename_outline_rounded,
            ),
            // 「删除会话」是破坏性操作，与前两项分开一组。
            AgentMenuItem<String>(
              value: 'delete',
              label: '删除会话',
              icon: Icons.delete_outline_rounded,
              dividerBefore: true,
            ),
          ],
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'float':
            widget.onFloat?.call();
          case 'close':
            _close();
          case 'rename':
            unawaited(_rename());
          default:
            unawaited(_delete());
        }
      },
      builder: (context, controller, open, hovering) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (mobile) {
          return MobileTopBarButton(
            glyph: MobileTopBarGlyph.more,
            tooltip: '会话操作',
            onPressed: toggle,
          );
        }
        return IconButton(
          tooltip: '会话操作',
          onPressed: toggle,
          // 尺寸与栏头其它按钮一致：命中区 24、图标 14、8dp 圆角方形悬停底。
          style: _menuButtonStyle,
          iconSize: kPaneHeaderIconSize,
          icon: const Icon(Icons.more_horiz),
        );
      },
    );
  }

  Future<void> _send() async {
    final client = ref.read(apiClientProvider);
    if (_sending || client == null) {
      return;
    }

    final text = composerText(_input);

    // 文档里有技能标签：这一下不是聊天，是派任务。
    // 技能从文档里读，不另存状态——用户退格删掉标签后就不该再按技能派。
    final skill = firstSkillName(_input);

    // 附件同样从文档里读：芯片还在上传时不能发（服务端拿不到 id，
    // 发出去等于把它们静默丢掉），技能与附件同时存在时也不猜用户想干什么。
    final attachments = attachmentEmbeds(_input);
    if (attachments.any((embed) => embed.uploading)) {
      setState(() => _error = '还有附件正在上传，请稍等一下');
      return;
    }
    // 只带"已就绪"的那几枚：上传失败的芯片还在文档里（用户能看见、能删），
    // 但它没有服务端 id，发出去只会得到一个空引用。
    final sentAttachments = attachments
        .where((embed) => embed.ready)
        .toList(growable: false);
    final attachmentIds = sentAttachments
        .map((embed) => embed.id)
        .toList(growable: false);

    if (skill != null && attachments.isNotEmpty) {
      setState(() => _error = '技能标签与附件不能同时发送，请先移除其中一项');
      return;
    }

    if (skill != null) {
      // 只有标签、没打字也派：技能自带流程，"用这个办"就是完整意图。
      // 这个分支必须排在"文本为空"之前，否则选了技能直接回车会静默无事发生。
      await _dispatchAtSkill(skill, text);
      return;
    }

    // 只发附件不写文字是合法输入："就发这张图"本身就是完整意图。
    if (text.isEmpty && attachmentIds.isEmpty) {
      return;
    }

    final clientMessageId =
        'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

    final now = DateTime.now().millisecondsSinceEpoch;

    setState(() {
      _sending = true;
      _stopping = false;
      _activeClientMessageId = clientMessageId;
      _error = null;
      _messages.add(
        ChatMessage(
          id: 'local-$clientMessageId',
          role: 'user',
          content: text,
          // 乐观上屏时就把附件带上：气泡里的芯片与输入框里那几枚必须对得上，
          // 否则用户会以为附件没发出去。
          attachments: sentAttachments
              .map((embed) => embed.toModel())
              .toList(growable: false),
          // 时间戳当场打上：用户发言的时间就是这一下，不必等服务端回包。
          createdAt: now,
        ),
      );
      _messages.add(
        ChatMessage(
          id: 'streaming',
          role: 'assistant',
          content: '',
          streaming: true,
          createdAt: now,
        ),
      );
      _streamingIndex = _messages.length - 1;
      // 上一轮的步骤不能漏进这一轮：换消息就换一份过程。
      _streamSteps.clear();
      // 产物卡同理：暂存表只服务本轮，跨轮带走会让只读的一轮凭空多出一张卡。
      _pendingFileWrites.clear();
      clearComposer(_input);
    });
    _scrollToBottom();

    // 当前配置不认这个参数时一个字段都不发：服务端也会按能力位拦一次，
    // 但请求形状保持一致，排障时少一层"到底是谁拦的"。
    final reasoningSupported = ref.read(activeModelProvider)?.reasoning ?? false;
    final effort = reasoningSupported
        ? ref.read(composerReasoningProvider(widget.conversationId))
        : null;

    try {
      final events = client.postSse(
        '/api/conversations/${widget.conversationId}/messages',
        chatMessageBody(
          content: text,
          clientMessageId: clientMessageId,
          attachments: attachmentIds,
          reasoningEffort: effort,
        ),
      );

      // 显式订阅而不是 `await for`：停止时要从外面把它掐掉。
      final done = Completer<void>();
      _streamDone = done;
      _stream = events.listen(
        _handleStreamEvent,
        onError: (Object error) {
          // 传输层错误：已收到的片段照样留着，只把状态标成失败。
          if (mounted) {
            _flushDelta();
            _markStreamFailed();
            setState(() {
              _error = error is ApiException ? error.userMessage : '生成中断';
            });
          }
          // `cancelOnError` 之后不会再来 onDone：这里必须自己放行，
          // 否则 `_send` 的收尾分支永远等不到，界面会卡在"生成中"。
          if (!done.isCompleted) {
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        },
        // 出过错就别再读了：错误已经交给上面处理，继续读只会重复标记。
        cancelOnError: true,
      );

      await done.future;
    } finally {
      _stopFallback?.cancel();
      _stopFallback = null;
      _stream = null;
      _streamDone = null;

      if (mounted) {
        // 流可能在中途断掉：收尾前把缓冲区里剩下的字补上。
        _flushDelta();
        // 点了停止却没等到服务端的收尾事件（超时兜底、或服务端直接断开流）：
        // 在本地把这条消息标成"已停止"，不能再显示"生成中"。
        if (_stopping) {
          _markStreamStopped();
        }
        setState(() {
          _sending = false;
          _stopping = false;
          _streamingIndex = null;
        });
        _activeClientMessageId = null;
        _scrollToBottom();
        unawaited(_syncTitleAfterAnswer());
      }
    }
  }

  /// 处理一条 SSE 事件。
  void _handleStreamEvent(Map<String, dynamic> event) {
    if (!mounted) {
      return;
    }
    switch (event['type']) {
      case 'message_delta':
        _appendDelta(event['text'] as String? ?? '');
      case 'message_completed':
        _finishStream(
          event['message_id'] as String?,
          _parseSources(event['sources']),
          _parseSuggestions(event['task_suggestions']),
          _parseFileWrites(event['file_writes']),
          _parseSteps(event['steps']),
          _parseMedia(event['media']),
          elapsedMs: event['elapsed_ms'] as int? ?? 0,
          usage: _parseUsage(event['usage']),
          finishReason: event['finish_reason'] as String?,
          notice: event['notice'] as String?,
        );
      case 'file_write_request':
        // 覆盖确认卡：内容已经在服务端落库，这里只负责让它尽早出现。
        // 收尾时的 `message_completed` 会再给一份，届时以那份为准。
        final write = _fileWriteFromEvent(event);
        if (write != null) {
          setState(() => _pendingFileWrites[write.requestId] = write);
        }
      case 'tool_activity':
        // 工具执行进度。工具调用不产生正文分片，不记录这条的话，
        // 用户在整个"读文件 / 写文件"期间只能看到一个静止的省略号。
        _applyToolActivity(event);
      case 'open_url':
        // 工具请求打开页面：服务端只给地址，开在哪里由客户端决定。
        // `display` 是可读的逻辑地址（项目名 + 相对路径），真实地址里
        // 带随机端口与访问令牌，只用于加载。
        final url = event['url'] as String?;
        final display = event['display'] as String?;
        if (url != null && url.isNotEmpty) {
          unawaited(_openToolUrl(url, display: display));
        }
      case 'error':
        // 出错前已收到的片段也要露出来，不能因为一个错误整段清空。
        _flushDelta();
        _markStreamFailed();
        setState(() {
          _error = event['hint'] as String? ?? '生成失败';
        });
      default:
        break;
    }
  }

  /// `preview_url` 要求的打开动作。
  ///
  /// 打开位置与文件树右键「预览」共用 [`openPreviewInPanel`]：
  /// 宽屏开右栏标签、窄屏推整页面板。这里只负责算出"当前是不是宽屏"——
  /// 停靠与浮窗都只出现在宽屏三栏里，整页形态才按窗口宽度判断。
  Future<void> _openToolUrl(String url, {String? display}) async {
    if (!mounted) {
      return;
    }

    await openPreviewInPanel(
      context,
      ref,
      url: url,
      wide: _isWide(),
      display: display,
    );
  }

  /// 把一条 `tool_activity` 合并进当前消息的执行过程。
  ///
  /// 同一 `call_id` 先来 `running`、再来 `ok`/`failed`：按 id 更新同一行，
  /// 列表顺序就是执行顺序。写成"每次都 push 一条"会让一次读文件显示两遍。
  void _applyToolActivity(Map<String, dynamic> event) {
    final index = _streamingIndex;
    if (!mounted || index == null || index >= _messages.length) {
      return;
    }

    final id = event['id'] as String? ?? '';
    final label = event['label'] as String? ?? '';
    if (id.isEmpty || label.isEmpty) {
      return;
    }

    final phase = event['phase'] as String? ?? 'running';
    final running = phase == 'running';
    final ok = phase != 'failed';
    final elapsedMs = (event['elapsed_ms'] as num?)?.toInt() ?? 0;

    setState(() {
      final at = _streamSteps.indexWhere((step) => step.id == id);
      if (at >= 0) {
        _streamSteps[at] = _streamSteps[at].copyWith(
          label: label,
          ok: ok,
          elapsedMs: elapsedMs,
          running: running,
        );
      } else {
        _streamSteps.add(
          ChatStep(
            id: id,
            tool: event['tool'] as String? ?? '',
            label: label,
            ok: ok,
            elapsedMs: elapsedMs,
            running: running,
          ),
        );
      }
      _messages[index] = _messages[index].copyWith(
        steps: List<ChatStep>.unmodifiable(_streamSteps),
      );
    });
  }

  /// 覆盖 / 取消。服务端已经把待写内容落库，这里只需要一个决定。
  ///
  /// 不复用对话流：决策是异步的，用户可能过几分钟才点，
  /// 甚至跨界重进会话——挂起一轮生成等它是不必要的复杂。
  Future<void> _decideFileWrite(FileWriteView write, bool approve) async {
    final client = ref.read(apiClientProvider);
    if (client == null || _fileWriteBusy.contains(write.requestId)) {
      return;
    }

    setState(() => _fileWriteBusy.add(write.requestId));
    try {
      final json = await client.postJson(
        '/api/conversations/${widget.conversationId}/file-writes/${write.requestId}',
        <String, dynamic>{'approve': approve},
      );
      _replaceFileWrite(FileWriteView.fromJson(json));
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.userMessage);
    } finally {
      if (mounted) {
        setState(() => _fileWriteBusy.remove(write.requestId));
      }
    }
  }

  /// 打开生成的文件。**落点统一是右侧栏**，但入口分两种：
  ///
  /// - 网页（html/htm）：仍走 `/file-preview` 换地址，落进浏览器标签。
  ///   预览站只托管网页与静态资源，把 html 塞进代码查看器反而看不懂；
  /// - 项目内其它文件：落进预览标签（文本 / 图片 / PDF / 视频都由
  ///   `previewKindOf` 分流）。草案里的同类型文件打不开——服务端没有
  ///   "读草案正文"的接口，卡片上也不会给这个按钮（见 [FileWriteView] 的判定）。
  Future<void> _openFileWrite(FileWriteView write) async {
    if (write.previewable) {
      await _openFileWritePage(write);
      return;
    }
    if (!write.inProject || widget.projectId.isEmpty) {
      return;
    }
    final wide = _isWide();
    await revealPreviewTab(
      context,
      ref,
      source: PreviewSource.file(
        projectId: widget.projectId,
        path: write.path,
      ),
      title: fileNameOf(write.path),
      wide: wide,
    );
  }

  /// 把生成文件另存到本机。项目内与草案各走一条字节通道，
  /// 建议文件名都是文件自己的名字（不带会话标题——这是用户自己命名的文件）。
  Future<void> _saveFileWrite(FileWriteView write) async {
    if (write.inProject) {
      if (widget.projectId.isEmpty) {
        return;
      }
      await saveProjectFile(
        context,
        ref,
        projectId: widget.projectId,
        path: write.path,
      );
      return;
    }
    await saveDraftFile(
      context,
      ref,
      conversationId: widget.conversationId,
      path: write.path,
    );
  }

  /// 网页类生成文件：换成预览站地址，落进右栏浏览器标签。
  Future<void> _openFileWritePage(FileWriteView write) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    try {
      final json = await client.getJson(
        '/api/conversations/${widget.conversationId}/file-preview',
        query: <String, String>{'path': write.path},
      );
      final url = json['url'] as String?;
      if (url == null || url.isEmpty) {
        return;
      }
      await _openToolUrl(url, display: json['display'] as String? ?? write.path);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.userMessage);
    }
  }

  /// 打开图片 / 视频产物：与文件同一落点——右侧栏预览标签。
  Future<void> _openMediaPreview(MediaAsset asset) async {
    if (!mounted) {
      return;
    }
    await revealPreviewTab(
      context,
      ref,
      source: PreviewSource.media(
        asset: asset,
        conversationTitle: _title,
      ),
      title: artifactTabTitle(kind: asset.kind, createdAtMs: asset.createdAt),
      wide: _isWide(),
    );
  }

  /// 宽屏（三栏）：停靠与浮窗形态都只出现在宽屏里，整页形态才看窗口宽度。
  bool _isWide() =>
      widget.presentation != ChatPresentation.page ||
      MediaQuery.sizeOf(context).width >= kShellBreakpoint;

  /// 当前是窄屏布局（一栏），与外壳的宽窄切换同一个断点。
  ///
  /// 用它而不是 `presentation`：宽屏内嵌的中栏也可能被拖到 700 以下，
  /// 输入栏的形态该跟着可用宽度一起变（窄屏手机才做空闲折叠）。
  bool get _narrowLayout =>
      MediaQuery.sizeOf(context).width < kShellBreakpoint;

  /// 窄屏 + 移动端：只有这一种组合才做「空闲折叠成一行」。
  ///
  /// 判断不缓存（getter 每次现取）：测试里换 `debugDefaultTargetPlatformOverride`
  /// 才能生效，平台本来也不会在运行时变。桌面把窗口拖窄仍保持完整输入栏。
  bool get _mobileNarrow =>
      isMobilePlatform(defaultTargetPlatform) && _narrowLayout;

  /// 收起系统键盘：手机窄屏点消息区 / 空白处时用。
  void _dismissKeyboard() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null) {
      focus.unfocus();
    }
  }

  /// 用服务端返回的最新状态替换本地那张卡（按 request_id 找）。
  ///
  /// 卡片可能还在"先到一步"的暂存表里，也可能是已落库消息的一部分，两处都更新。
  ///
  /// 暂存表**只装本轮、且只装待确认的卡**：收尾时已经被清空，这时点确认返回的
  /// 已写入结果不该再放回去——它属于那条消息，留在表里会被下一轮的
  /// `message_completed` 合并进去，界面于是给一轮只读的回答凭空挂一张产物卡。
  void _replaceFileWrite(FileWriteView updated) {
    if (!mounted) {
      return;
    }

    setState(() {
      // 用 `containsKey` 判断而不是直接赋值：只有"收尾前就出现过"的卡才需要
      // 在暂存表里跟着更新，否则等于把一张已终结的卡重新复活。
      if (_pendingFileWrites.containsKey(updated.requestId)) {
        _pendingFileWrites[updated.requestId] = updated;
      }
      for (var i = 0; i < _messages.length; i++) {
        final message = _messages[i];
        if (message.fileWrites.isEmpty) {
          continue;
        }
        final at = message.fileWrites.indexWhere(
          (write) => write.requestId == updated.requestId,
        );
        if (at < 0) {
          continue;
        }
        final next = List<FileWriteView>.of(message.fileWrites);
        next[at] = updated;
        _messages[i] = message.copyWith(fileWrites: next);
      }
    });
  }

  /// 停止本轮生成。
  /// 切换审批方式。「完全放行」必须先过二次确认，取消则保持原值。
  Future<void> _selectPermission(String value) async {
    if (value == ApprovalModes.trust && !await confirmFullAccess(context)) {
      return;
    }
    if (!mounted) {
      return;
    }
    ref
        .read(composerApprovalProvider(widget.conversationId).notifier)
        .select(value);
  }

  ///
  /// 顺序是"先请服务端收尾，再等服务端的完成事件"，**不是**直接断流：
  /// 服务端把断开连接当成"没人要了"，会把半截回答丢掉——那样停止就等于撤销，
  /// 用户辛苦等出来的半段文字会消失。只有 `POST /stop` 才会让服务端把它落库。
  Future<void> _stop() async {
    if (!_sending || _stopping) {
      return;
    }
    final client = ref.read(apiClientProvider);
    final clientMessageId = _activeClientMessageId;
    setState(() => _stopping = true);

    // 兜底先挂上再发请求：请求本身可能卡住，界面不能一直停在"生成中"。
    _stopFallback?.cancel();
    _stopFallback = Timer(stopFallbackDelay, _stopLocally);

    if (client == null || clientMessageId == null) {
      _stopLocally();
      return;
    }

    try {
      await client.postJson(
        '/api/conversations/${widget.conversationId}/stop',
        <String, String>{'client_msg_id': clientMessageId},
      );
    } on ApiException {
      // 服务端没接住（旧版本没有这个接口，或网络半死）：退化成本地断流。
      // 代价是这半截回答不会进历史，但"点了停止"必须真的停下。
      _stopLocally();
    }
  }

  /// 本地收尾：取消订阅并放行 `_send` 的收尾分支。
  ///
  /// 连接一断，服务端那边的生成也会停（它靠发送失败判断对面走了），
  /// 所以这里不需要第二层通知。
  void _stopLocally() {
    _stopFallback?.cancel();
    _stopFallback = null;

    final stream = _stream;
    _stream = null;
    unawaited(stream?.cancel());

    final done = _streamDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  void _appendDelta(String piece) {
    if (piece.isEmpty) {
      return;
    }
    _deltaBuffer.write(piece);
    _deltaTimer ??= Timer(streamFlushInterval, _flushDelta);
  }

  /// 把缓冲的增量合并进当前消息。[_finishStream] 依赖它拿到完整正文，
  /// 所以完成、异常、收尾三处都必须先 flush。
  void _flushDelta() {
    _deltaTimer?.cancel();
    _deltaTimer = null;

    if (_deltaBuffer.isEmpty) {
      return;
    }
    final piece = _deltaBuffer.toString();
    _deltaBuffer.clear();

    final index = _streamingIndex;
    if (!mounted || index == null || index >= _messages.length) {
      return;
    }
    final updated = _messages[index].copyWith(
      content: _messages[index].content + piece,
    );
    setState(() => _messages[index] = updated);
    // 用户已经往上翻历史时不再拽回底部：新内容静默落在下面，
    // 想看得自己点"回到底部"。
    _scrollToBottom(force: false);
  }

  void _finishStream(
    String? messageId,
    List<MessageSource> sources,
    List<TaskSuggestion> suggestions,
    List<FileWriteView> fileWrites,
    List<ChatStep> steps,
    List<MediaAsset> media, {
    int elapsedMs = 0,
    TokenUsage? usage,
    String? finishReason,
    String? notice,
  }) {
    // 最后一批增量可能还在缓冲里：这里不 flush，回答结尾会缺一段。
    _flushDelta();

    final index = _streamingIndex;
    if (index == null || index >= _messages.length) {
      return;
    }

    // 先到一步的确认卡与消息里的权威列表合并：同 id 以消息里的为准。
    final mergedWrites = <String, FileWriteView>{
      for (final write in _pendingFileWrites.values) write.requestId: write,
      for (final write in fileWrites) write.requestId: write,
    }.values.toList(growable: false);

    // 步骤以服务端那份为准：它带最终耗时与失败标记。流式累积只在
    // 服务端没给（老服务端、异常路径）时兜底，总比什么都不显示强。
    final mergedSteps = steps.isNotEmpty
        ? steps
        : List<ChatStep>.unmodifiable(_streamSteps);

    setState(() {
      _pendingFileWrites.clear();
      _streamSteps.clear();
      _messages[index] = ChatMessage(
        id: messageId ?? _messages[index].id,
        role: 'assistant',
        content: _messages[index].content,
        sources: sources,
        suggestions: suggestions,
        fileWrites: mergedWrites,
        media: media,
        steps: mergedSteps,
        // 回答的时间以收尾这一刻为准：这段文字是刚写完的，不是刚开始写的。
        createdAt: DateTime.now().millisecondsSinceEpoch,
        elapsedMs: elapsedMs,
        usage: usage,
        finishReason: finishReason,
      );
      // 系统提示（例如「已记住：…」）插在回答之前，与服务端落库顺序一致；
      // 它已经落库，退出重进会从历史里读到同一条，这里只补本次会话的显示。
      final noticeId = 'notice-$messageId';
      if (notice != null &&
          notice.trim().isNotEmpty &&
          !_messages.any((message) => message.id == noticeId)) {
        _messages.insert(
          index,
          ChatMessage(
            id: noticeId,
            role: 'system',
            content: notice,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      _streamingIndex = null;
    });
    // 新回答可能带着建议卡：立刻拉一次任务状态，卡片从第一帧就是准的。
    _syncSuggestionPolling();
  }

  /// 生成中断：把正在写的那条标成失败，状态行不能再显示"已完成"。
  void _markStreamFailed() {
    final index = _streamingIndex;
    if (index == null || index >= _messages.length) {
      return;
    }
    setState(() {
      _messages[index] = _messages[index].copyWith(
        streaming: false,
        failed: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
    });
  }

  /// 用户停止：保留已收到的文字，终态记成 stopped（与服务端同一个值）。
  ///
  /// 一个字都没生成就停时不留下空气泡：服务端在这种情况下也不写历史，
  /// 两边都当这一轮没发生过。
  void _markStreamStopped() {
    final index = _streamingIndex;
    if (index == null || index >= _messages.length) {
      return;
    }
    if (_messages[index].content.trim().isEmpty) {
      setState(() {
        _messages.removeAt(index);
        _streamingIndex = null;
      });
      return;
    }
    setState(() {
      _messages[index] = _messages[index].copyWith(
        streaming: false,
        finishReason: 'stopped',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _streamingIndex = null;
    });
  }

  /// 打开一条任务：宽屏右侧原地切换，窄屏整页 push。
  Future<void> _openTask(String taskId) async {
    final openTask = widget.onOpenTask;
    if (openTask != null) {
      openTask(taskId);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TaskDetailPage(taskId: taskId)),
    );
  }

  /// 用户点了建议卡：这一刻才真正创建任务。
  ///
  /// 幂等键带上 message_id：反复点击（或重进会话再点）只会得到同一个任务，
  /// 不会因为"手抖两下"派出两件活。
  Future<void> _dispatchSuggestion(
    ChatMessage message,
    TaskSuggestion suggestion,
  ) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    final key = _suggestionKey(message.id, suggestion.skill);
    final current = _dispatchStates[key];
    if (current == 'creating' || current == 'created') {
      return;
    }

    // 建议已经派出去过：点卡片只负责打开任务，不再弹"要改什么"。
    final existing = _suggestionTasks[key];
    if (existing != null) {
      await _openTask(existing.id);
      return;
    }

    // 可能只是本地还没拉到（刚进会话 / 轮询还没回来）：补一次再决定，
    // 别让"任务正在跑"时又弹创建框。补拉失败就按没派过处理。
    await _refreshSuggestionTasks();
    if (!mounted) {
      return;
    }
    final refreshed = _suggestionTasks[key];
    if (refreshed != null) {
      await _openTask(refreshed.id);
      return;
    }

    setState(() {
      _dispatchStates[key] = 'creating';
      _error = null;
    });

    // 编码任务只需要用户补一句"要改什么"：仓库由会话所属的 Git 项目提供，
    // 模型的建议里没有仓库，也不该让它替用户挑一个。
    var input = suggestion.input;
    if (suggestion.skill == 'code-task') {
      if (!mounted) {
        return;
      }
      // 先取清单再开弹窗：没预热过时 `.value` 是 null，会让第一次打开没有
      // "执行方式"、第二次才有。拉不到就按"自动"处理，不挡住派单。
      final providers = await readCodeProviders(ref);
      if (!mounted) {
        return;
      }
      final code = await showCodeTaskInputDialog(
        context,
        projectPath: widget.projectPath,
        initialInstruction: suggestion.reason,
        providers: providers,
      );
      if (code == null) {
        if (mounted) {
          setState(() => _dispatchStates.remove(key));
        }
        return;
      }
      input = codeTaskInputJson(
        input: code,
        base: suggestion.input,
        // 输入栏选的审批方式随任务下发：worker 据此决定"要不要问人"。
        approval: ref.read(composerApprovalProvider(widget.conversationId)),
      );
    }

    try {
      final created = await client.postJson('/api/tasks', <String, dynamic>{
        'conversation_id': widget.conversationId,
        'type': 'skill:${suggestion.skill}',
        'skill': suggestion.skill,
        'input': input,
        'idempotency_key':
            'conv:${widget.conversationId}:msg:${message.id}:skill:${suggestion.skill}',
      });

      if (!mounted) {
        return;
      }
      final taskId = created['id'] as String? ?? '';
      final task = TaskView.fromJson(created);
      setState(() {
        _dispatchStates[key] = 'created';
        if (taskId.isNotEmpty) {
          _suggestionTasks[key] = task;
        }
      });
      _syncSuggestionPolling();
      if (taskId.isEmpty) {
        return;
      }
      await _openTask(taskId);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dispatchStates[key] = 'failed';
        _error = error.userMessage;
      });
    }
  }

  /// `@技能` 派任务：先解析参数，再建任务，卡片挂到消息流末尾。
  ///
  /// 解析失败不挡派单：服务端只带原文返回（`source=fallback`），缺的字段在
  /// `missing` 里，卡片上说明「可能读不到资料」，由用户自己补。
  Future<void> _dispatchAtSkill(String skill, String text) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      return;
    }

    final seq = DateTime.now().microsecondsSinceEpoch.toString();
    final entry = AtTaskView(key: 'at:$seq:$skill', skill: skill);

    setState(() {
      // 清空文档：技能标签也在文档里，一并没了。
      clearComposer(_input);
      _atTasks.add(entry);
    });
    _scrollToBottom();

    try {
      final prepared = PreparedTaskInput.fromJson(
        await client.postJson('/api/tasks/prepare', <String, dynamic>{
          'conversation_id': widget.conversationId,
          'skill': skill,
          'text': text,
        }),
      );

      final created = await client.postJson('/api/tasks', <String, dynamic>{
        'conversation_id': widget.conversationId,
        'type': 'skill:$skill',
        'skill': skill,
        'input': prepared.input,
        // 带时间戳：同一个技能连发两次是两件事，不该被幂等键合并成一件。
        'idempotency_key': 'at:${widget.conversationId}:$seq:$skill',
      });

      if (!mounted) {
        return;
      }

      setState(() {
        entry
          ..task = TaskView.fromJson(created)
          ..missing = prepared.missing
          ..state = 'created';
      });
      _syncSuggestionPolling();
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        entry
          ..state = 'failed'
          ..error = error.userMessage;
      });
      _toast(error.userMessage);
    }
  }

  /// 滚到底部。
  ///
  /// [force] 为假表示"只在本来就在底部时才跟随"：流式输出每 80ms 调一次，
  /// 无条件滚会把人从历史里一路拽回底部。
  void _scrollToBottom({bool force = true}) {
    if (!force && !_atBottom) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      final target = position.maxScrollExtent;
      final distance = (target - position.pixels).abs();
      _lastMaxExtent = target;
      if (distance < 0.5) {
        return;
      }
      // 大跨度落位（首屏、形态切换）直接跳：动画会和弹性物理的清算打架。
      if (distance > _maxAnimatedScroll) {
        _scroll.jumpTo(target);
        return;
      }
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  /// 帧后直接落到底部，不做滚动动画。
  ///
  /// 历史 + 媒体卡片是"一次成型的整屏"，没有需要被看见的滚动过程；用
  /// `animateTo` 反而会让它和目标位置赛跑（目标值还是骨架高度时算出来的）。
  ///
  /// [attempt] 是补帧次数：`ListView.builder` 第一帧只能用"已布局项的平均高度"
  /// 外推剩下的内容，`maxScrollExtent` 是个估值；跳到估值之后真实值才落定，
  /// 差值就是一段越界距离。补一帧抹平，别留给弹性物理去弹。
  void _jumpToBottom({int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      final target = position.maxScrollExtent;
      _lastMaxExtent = target;
      if ((target - position.pixels).abs() >= 0.5) {
        _scroll.jumpTo(target);
      }
      if (attempt >= 1) {
        return;
      }
      _jumpToBottom(attempt: attempt + 1);
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  /// 消息列表 + 贴窗口右边的滚动条 + "回到底部"浮标。
  ///
  /// 滚动条要压在窗口最右侧，而内容仍限宽 720 居中：`Scrollbar` 只能画在
  /// 自己的布局盒右边，所以列表铺满整宽，把限宽交给每个 item——这样拇指条
  /// 落在窗口边缘，正文仍在中间，两侧不会出现"轨道漂在内容旁边"的观感。
  Widget _messageList() {
    // 浮窗的贴底输入栏用 12 的左右边距（见 `_composerArea`），气泡跟着收窄，
    // 两者才是同一条竖线；中栏/整页仍是 16。
    final sideInset = widget.presentation == ChatPresentation.floating ? 12.0 : 16.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 浮标贴在内容列右下：宽屏下不能跟着窗口边缘跑到屏幕最右。
        final overflow = constraints.maxWidth - kChatColumnMaxWidth;
        final side = overflow > 0 ? overflow / 2 : 0.0;

        return Stack(
          children: <Widget>[
            Positioned.fill(
              // 尺寸变化（不是滚动手势）的通知走这里：内容变矮时把贴底的
              // 列表钉回底部，避免它悬在内容之外做长回弹。
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: _handleScrollMetrics,
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  thickness: 6,
                  radius: const Radius.circular(3),
                  child: ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(sideInset, 16, sideInset, 16),
                    // `@` 派出的任务卡接在消息流末尾：它们是本轮会话的动作，
                    // 不挂靠某条消息，位置也不能随消息增删漂移。
                    itemCount: _messages.length + _atTasks.length,
                    itemBuilder: (context, index) {
                      if (index >= _messages.length) {
                        final entry = _atTasks[index - _messages.length];
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: kChatColumnMaxWidth,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 20),
                              child: AtTaskCard(
                                entry: entry,
                                onOpen: () {
                                  final id = entry.task?.id ?? '';
                                  if (id.isNotEmpty) {
                                    unawaited(_openTask(id));
                                  }
                                },
                              ),
                            ),
                          ),
                        );
                      }
                      final message = _messages[index];
                      final compaction = _compaction;
                      // 横条插在"第一条没被折叠"的消息之前；锚点滚出列表
                      // （超过 50 条历史）时挂在最上面，否则用户永远看不到它。
                      final showBar = compaction != null &&
                          compaction.anchorMessageId != null &&
                          (compaction.anchorMessageId == message.id ||
                              (index == 0 && _compactionBarAtTop));
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: kChatColumnMaxWidth,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              if (showBar)
                                CompactionBar(
                                  view: compaction,
                                  onOpen: _openCompactionDialog,
                                ),
                              Padding(
                                // 间距放在 item 上而不是气泡里：助手回答没有背景，
                                // 靠这里的留白分块，不靠卡片边距。
                                padding: const EdgeInsets.only(bottom: 20),
                                child: MessageBubble(
                                  message: message,
                                  dispatchStates: _dispatchStates,
                                  suggestionTasks: _suggestionTasks,
                                  onDispatch: (suggestion) =>
                                      _dispatchSuggestion(message, suggestion),
                                  onOpenTask: _openTask,
                                  onDecideFileWrite: _decideFileWrite,
                                  onOpenFileWrite: _openFileWrite,
                                  onSaveFileWrite: _saveFileWrite,
                                  onOpenMedia: _openMediaPreview,
                                  fileWriteBusy: _fileWriteBusy,
                                  // 标题随时可能被自动改写：跟 `_title` 走，
                                  // 产物另存时的自动名才是"此刻"的会话名。
                                  conversationTitle: _title,
                                  canSaveMediaToProject:
                                      widget.canSaveMediaToProject,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              right: side + 12,
              bottom: 12,
              child: IgnorePointer(
                ignoring: _atBottom,
                child: AnimatedOpacity(
                  key: jumpToBottomKey,
                  opacity: _atBottom ? 0 : 1,
                  duration: const Duration(milliseconds: 150),
                  child: _JumpToBottomButton(onTap: () => _scrollToBottom()),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 新会话的居中舞台：品牌行 + 输入栏。
  ///
  /// 舞台与品牌行都在 `new_session_stage.dart`：宽屏中栏的「聊天」空态页
  /// 用的是同一块，两处各画一套会让同一个开场长出两种留白。
  Widget _newSessionStage() => NewSessionStage(
    // 中线按整个窗口算：把上方栏头的高度交给舞台扣掉。
    chromeAbove: switch (widget.presentation) {
      ChatPresentation.page => kToolbarHeight + MediaQuery.paddingOf(context).top,
      ChatPresentation.docked => kPaneHeaderHeight,
      // 浮窗自己就是窗口中间的一小块，再按整窗扣栏头会把它顶出框。
      // 会话页的浮窗形态已不走舞台（见 `_body`），这条留给直接构造舞台的入口。
      ChatPresentation.floating => 0,
    },
    composer: _composerArea(centered: true),
  );

  /// 手机窄屏的新会话：只有品牌行居中，输入栏留在底部（见 `_body` 的 `brandOnly`）。
  ///
  /// 不复用 [NewSessionStage]：舞台把「品牌行 + 输入栏」当整体居中，而这里的输入栏
  /// 是贴底的，复用只会把输入栏顶回中线。品牌行本身仍用同一枚组件，文案与字号
  /// 不会与宽屏的开场分叉。
  Widget _mobileBrand() => const Center(child: NewSessionBrand());

  /// 压缩横条是否挂在列表最上面。
  ///
  /// 锚点可能已经滚出最近加载的那批消息：那时若坚持按位置插入，
  /// 横条会永远不显示——用户就看不出"更早的内容已经被整理过"。
  bool get _compactionBarAtTop {
    final anchor = _compaction?.anchorMessageId;
    if (anchor == null) {
      return false;
    }
    return !_messages.any((message) => message.id == anchor);
  }

  /// 最近一条助手消息的上下文长度（本轮最后一次模型调用的输入 token）。
  ///
  /// 倒序找第一条带用量的助手消息即可：长会话里不必正序扫全表；
  /// 新会话还没有回答时返回 0，输入栏的环形显示空环。
  int get _latestContextTokens {
    for (final message in _messages.reversed) {
      final usage = message.usage;
      if (message.role == 'assistant' && usage != null) {
        return usage.contextTokens;
      }
    }
    return 0;
  }

  /// 输入栏。
  ///
  /// 外框（`SafeArea` / 页边距 / 限宽）收在 [ChatComposerArea]：居中列与贴底列
  /// 共用同一套度量，消息列表的左右边缘才会跟输入栏对齐。
  ///
  /// [centered] 是给新会话舞台用的：那块上下都是空白，垂直边距交给舞台按品牌行
  /// 的高度补，面板才是真正的垂直居中，品牌行到面板的间距也才等于舞台里写的值。
  Widget _composerArea({bool centered = false}) {
    final floating = widget.presentation == ChatPresentation.floating;
    return ChatComposerArea(
      controller: _input,
      sending: _sending,
      stopping: _stopping,
      flowing: _sending,
      onSend: _send,
      onStop: _stop,
      permission: ref.watch(composerApprovalProvider(widget.conversationId)),
      onPermissionChanged: _selectPermission,
      reasoning: ref.watch(composerReasoningProvider(widget.conversationId)),
      onReasoningChanged: (value) => ref
          .read(composerReasoningProvider(widget.conversationId).notifier)
          .select(value),
      // 上下文环的分母取当前生效模型的窗口，分子取最近一条助手消息的用量：
      // 两者都已经是页面手上的数据，不必再拉一次接口。
      contextWindow: ref.watch(activeModelProvider)?.contextWindow ?? 0,
      contextTokens: _latestContextTokens,
      // 只有"有可用摘要"时才算已压缩：失败记录不该让环上的提示变成一句谎话。
      compactedMessages: (_compaction?.hasSummary ?? false)
          ? _compaction!.sourceMessages
          : 0,
      // 手动整理期间环转圈：这是唯一"用户在等、且等多久不确定"的时刻。
      compacting: _compactionBusy,
      // 有压缩记录（哪怕只有失败）就能点开摘要：那里才说得清"为什么没有摘要"。
      // 没有记录时传 null，环回到纯展示，连手型光标都不给。
      onOpenCompaction: _compaction == null ? null : _openCompactionDialog,
      visibleLines: floating ? 1 : 2,
      // 手机窄屏空闲时收成一行（「+」/ 输入框 / 发送），键盘弹出或已有草稿才展开。
      compactWhenIdle: _mobileNarrow,
      padding: centered
          ? const EdgeInsets.symmetric(horizontal: 16)
          // 浮窗窄到铺满整窗时，左右与下取同一个值，面板到窗口三边等距。
          : floating
          ? ChatComposerArea.floatingPadding
          : null,
      // 浮窗悬在页面中间、居中舞台也不在屏幕底：让开安全区只多一条空白。
      safeBottom: !centered && !floating,
    );
  }

  /// 栏头：整页形态交给 AppBar，停靠用中栏工具行，浮窗用小窗标题行。
  ///
  /// 返回的 widget 类型会随形态变，但它永远占 `Column` 的第 0 个槽：
  /// 变的是这一格的内容，不是兄弟节点的数量或顺序。
  Widget _header(BuildContext context) {
    return switch (widget.presentation) {
      ChatPresentation.page => const SizedBox.shrink(),
      ChatPresentation.docked => EmbeddedToolbar(
        title: _title,
        emphasizeTitle: true,
        actions: <Widget>[
          // 整页形态不给「缩小」：路由上来的页面没有"缩到中栏"这回事。
          // 右栏收起时也不给：浮窗的意义是"腾出地方看别的东西"，这时窗格里
          // 只剩浮窗自己压在空白上，点了只会把唯一的内容区也丢掉。
          if (widget.onFloat != null && ref.watch(filePaneVisibleProvider))
            _floatButton(),
          _buildMenu(),
        ],
      ),
      ChatPresentation.floating => _floatingHeader(context),
    };
  }

  /// 停靠态栏头的「缩小为浮窗」。
  Widget _floatButton() {
    return IconButton(
      key: kChatFloatKey,
      tooltip: '缩小为浮窗',
      onPressed: widget.onFloat,
      style: _menuButtonStyle,
      iconSize: kPaneHeaderIconSize,
      // 自绘：参考图是"大框 + 左下角探出的小框、大框轮廓断开"，
      // Material 的 picture_in_picture_alt 是小框在右下，形状对不上。
      icon: const ChatFloatIcon(size: kPaneHeaderIconSize),
    );
  }

  /// 浮窗栏头：标题 + 「停靠」「…」「关闭」。
  ///
  /// 不摆会话图标：小窗本来就只有几百 dp 宽，右侧已经挤了三枚按钮，
  /// 再放一枚"这是会话"的图标是重复信息，还会把标题的可用宽度再压掉一档。
  /// 停靠态与整页形态仍然保留（那两处标题短、空间足）。
  ///
  /// 拖动区不在这里：它由浮窗外层盖一层透明手势区（见 `ChatWindowLayer`），
  /// 因为"窗口拖到哪儿"属于位置状态，不该让会话页知道。
  Widget _floatingHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);

    return Container(
      height: kPaneHeaderHeight,
      padding: const EdgeInsets.fromLTRB(kPaneContentInset, 0, 6, 0),
      decoration: BoxDecoration(
        // 浮窗内部的分隔线由自己画：骨架的横线层只在停靠态正好压在栏头下沿，
        // 浮起来之后那条线留在原来的窗口位置上，跟小窗没有关系了。
        border: Border(bottom: BorderSide(color: shellDividerColor(scheme))),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 与停靠态栏头的强调标题同档：同一段会话换个形态不该换一套字。
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: AppFontSize.md,
                fontWeight: AppWeight.semiBold,
                color: palette.text.primary,
              ),
            ),
          ),
          IconButton(
            key: kChatDockKey,
            tooltip: '停靠回中栏',
            onPressed: widget.onDock,
            style: _menuButtonStyle,
            iconSize: kPaneHeaderIconSize,
            icon: const Icon(Icons.open_in_full_rounded),
          ),
          _buildMenu(),
          IconButton(
            key: kChatFloatCloseKey,
            tooltip: '关闭小窗',
            onPressed: widget.onCloseWindow,
            style: _menuButtonStyle,
            iconSize: kPaneHeaderIconSize,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  /// 正文：错误条 / 消息区 / 输入栏。
  ///
  /// 三个槽位**恒定**，某一项当下不显示也留一个零高占位。`Column` 按索引匹配
  /// Element：`Expanded` 的索引一变（错误条出现、空会话切到有消息、停靠切浮窗），
  /// 消息列表与输入栏就会被整棵重建——滚动位置、正在流式的气泡、输入焦点一起丢。
  /// 对这一段来说，"位置不能动"比"看起来该不该显示"更重要。
  Widget _body(BuildContext context, {required bool newSession}) {
    final scheme = Theme.of(context).colorScheme;
    // 浮窗没有开场舞台：小窗只有几百 dp 高，把「探索未来 + 输入栏」
    // 一起顶到中线，输入栏离手太远，消息区还会被压成一条缝。它要的是
    // 「上方看内容、下方随手能打字」，所以空会话也直接走贴底分支。
    //
    // 手机窄屏同理不走舞台：输入栏固定贴底，舞台会把两者当整体居中、
    // 把输入栏顶回中线。那里只留品牌行居中（见 [brandOnly]）。
    final stage =
        newSession &&
        widget.presentation != ChatPresentation.floating &&
        !_mobileNarrow;

    // 手机窄屏的空会话：只有品牌行占一个视觉重心，输入栏仍贴在底部。
    final brandOnly =
        newSession &&
        widget.presentation != ChatPresentation.floating &&
        _mobileNarrow;

    return Column(
      children: <Widget>[
        // 槽 0：错误条。
        _error == null
            ? const SizedBox.shrink()
            : MaterialBanner(
                content: Text(_error!),
                leading: Icon(Icons.error_outline, color: scheme.error),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('知道了'),
                  ),
                ],
              ),
        // 槽 1：正文。空会话是居中舞台（品牌行 + 输入栏），否则是消息列表。
        // 浮窗不做舞台，空会话在这里就是一张空列表；手机窄屏只中间那行标语。
        Expanded(
          // 点消息区 / 空白处收起系统键盘（只有手机窄屏会真的动手）。
          //
          // 不用包住输入栏的 `TapRegion.onTapOutside`：模型 / 审批 / @ 候选都在
          // Overlay 里，那样点菜单项会被判成"点到了外面"，面板当场塌回去。
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _mobileNarrow ? _dismissKeyboard : null,
            child: stage
                ? _newSessionStage()
                : brandOnly
                ? _mobileBrand()
                : (_loading
                      ? const Center(child: CircularProgressIndicator())
                      : _messageList()),
          ),
        ),
        // 槽 2：输入栏。空会话的舞台自带一个，这里留零高占位。
        stage ? const SizedBox.shrink() : _composerArea(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = widget.presentation == ChatPresentation.page;
    final floating = widget.presentation == ChatPresentation.floating;

    // 没有消息就是新会话：居中放品牌行 + 输入栏。
    //
    // 这里刻意不再区分整页与内嵌：桌面宽屏的会话页以内嵌形态渲染
    // （见 `chat_window_layer.dart`），把它排除掉等于让桌面端永远看不到这个空态。
    // `_loading` 仍参与判定：打开一段已有历史的会话时不会先闪一下欢迎页；
    // 且没有可用客户端时历史加载直接返回、`_loading` 一直为 true，
    // 那条路径仍要看到贴底的输入栏。
    //
    // `_atTasks` 必须参与判定：`@` 派任务不产生消息，卡片只活在 `_atTasks`
    // 里。漏了它，空会话派出任务后舞台继续占着页面，卡片所在的列表
    // 根本没被构建——输入被清空、卡片看不见，跟"发送没反应"一模一样。
    final newSession = !_loading && _messages.isEmpty && _atTasks.isEmpty;

    return AppPageScaffold(
      // 底色按形态分：
      // - 整页：`AppPageScaffold` 铺整窗渐变（自铺、不透明，转场时不透下层列表）；
      // - 停靠：与左右两栏同一层半透明栏底，骨架的模式渐变才透得上来；
      // - 浮窗：实色。它下面是中栏内容，半透明会让底下的文字透出来。
      backgroundColor: page
          ? null
          : floating
          ? scheme.surface
          : paneSurfaceColor(scheme),
      appBar: page
          ? MobileAppBar(
              // 不传 [ChatPage.onBack] 时保持默认：路由里就是 pop 上一步。
              leading: widget.onBack == null
                  ? null
                  : MobileTopBarBackButton(onPressed: widget.onBack),
              titleWidget: _titleRow(context),
              actions: <Widget>[_buildMenu(mobile: true)],
            )
          : null,
      body: Column(
        children: <Widget>[
          // 槽 0：栏头。
          _header(context),
          // 槽 1：正文与输入栏。
          Expanded(child: _body(context, newSession: newSession)),
        ],
      ),
    );
  }
}

/// "回到底部"浮标：圆形、细描边、轻阴影。
///
/// 只画一个 chevron：它的语义单一，加文字反而要在小圆里挤两行。
class _JumpToBottomButton extends StatelessWidget {
  const _JumpToBottomButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 解析事件里的 `sources` 数组。形状不对就当没有来源，不让界面因此报错。
List<MessageSource> _parseSources(Object? raw) {
  if (raw is! List) {
    return const <MessageSource>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(MessageSource.fromJson)
      .where((source) => source.url.isNotEmpty)
      .toList(growable: false);
}

/// 解析事件里的 `usage`。形状不对就当没有统计——用量只是元信息，
/// 不能因为它让整条回答渲染失败。
TokenUsage? _parseUsage(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    return null;
  }
  final usage = TokenUsage.fromJson(raw);
  return usage.total > 0 ? usage : null;
}

/// 解析事件里的 `task_suggestions`。形状不对就当没有建议，不让界面因此报错。
List<TaskSuggestion> _parseSuggestions(Object? raw) {
  if (raw is! List) {
    return const <TaskSuggestion>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(TaskSuggestion.fromJson)
      .where((suggestion) => suggestion.skill.isNotEmpty)
      .toList(growable: false);
}

/// 解析事件里的 `file_writes`。与历史消息里的同一份结构，
/// 形状不对就当没有卡片。
List<FileWriteView> _parseFileWrites(Object? raw) {
  if (raw is! List) {
    return const <FileWriteView>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(FileWriteView.fromJson)
      .where((write) => write.requestId.isNotEmpty && write.path.isNotEmpty)
      .toList(growable: false);
}

/// 解析事件里的 `media`。形状不对就当没有卡片。
List<MediaAsset> _parseMedia(Object? raw) {
  if (raw is! List) {
    return const <MediaAsset>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(MediaAsset.fromJson)
      .where((media) => media.id.isNotEmpty && media.mime.isNotEmpty)
      .toList(growable: false);
}

/// 解析事件里的 `steps`。形状不对就当没有执行过程。
List<ChatStep> _parseSteps(Object? raw) {
  if (raw is! List) {
    return const <ChatStep>[];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(ChatStep.fromJson)
      .where((step) => step.label.isNotEmpty)
      .toList(growable: false);
}

/// `file_write_request` 事件 → 待确认卡片。
///
/// 事件字段比消息里的少（没有 status / created_at），按"刚创建、待确认"补齐。
FileWriteView? _fileWriteFromEvent(Map<String, dynamic> event) {
  final id = event['id'] as String?;
  final path = event['path'] as String?;
  if (id == null || id.isEmpty || path == null || path.isEmpty) {
    return null;
  }

  return FileWriteView(
    requestId: id,
    path: path,
    scope: event['scope'] as String? ?? 'draft',
    status: 'pending',
    bytes: (event['new_bytes'] as num?)?.toInt() ?? 0,
    existingBytes: (event['existing_bytes'] as num?)?.toInt() ?? 0,
    expiresAt: (event['expires_at'] as num?)?.toInt(),
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
}
