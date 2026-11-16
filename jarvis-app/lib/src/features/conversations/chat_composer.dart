import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_paths.dart';
import '../../core/session.dart';
import '../../core/ui/agent_menu.dart';
import 'attachment_embed.dart';
import 'at_skill_provider.dart';
import 'composer_attachments.dart';
import 'composer_context_ring.dart';
import 'composer_flow_border.dart';
import 'composer_menus.dart';
import 'composer_reasoning.dart';
import 'composer_text.dart';
import 'path_ref_embed.dart';
import 'skill_embed.dart';

/// 面板圆角。
const double _panelRadius = 20;

/// 当前平台能不能接收"从文件管理器拖进来"。
///
/// 只有桌面三端有这回事：移动端即使挂上 `DropTarget` 也收不到事件。
/// 判据集中在 [composerDesktopPlatform]，与「+」菜单里要不要给「粘贴图片」同源。
bool get _supportsFileDrop => composerDesktopPlatform;

/// 正悬在输入栏上方的是哪一类东西。
///
/// 两类拖入共用同一块高亮与同一句提示位，但文案不同：系统文件是"添加附件"，
/// 文件树拖来的是"引用路径"。这里只影响外观，不改布局高度。
enum _ComposerDropKind { files, pathRef }

/// 输入区单行高度。与正文 `14 / 1.5` 对齐。
const double _editorLineHeight = AppFontSize.base * AppLineHeight.normal;

/// 输入区默认显示两行。
///
/// 一行太像单行表单：写一句话就顶到内部滚动，而且面板会矮得像搜索框，
/// 和下方那排控件挤在一起。两行给出一块能看见"正在写一段话"的空白。
const int _defaultEditorLines = 2;

/// 输入区最多显示几行：超过后编辑器内部滚动，不会把输入栏撑满整屏。
const int _maxEditorLines = 6;

/// 面板除输入区以外的固定高度。
///
/// 18（面板内边距 10 + 8）+ 8（输入区上下各 4）+ 6（输入区与控件行的间距）
/// + 30（控件行，由发送按钮的圆撑开）。改这三处内边距时这里要跟着改，
/// 否则最小高度会与自然高度脱节。
const double _panelFixedHeight = 62;

/// 输入面板的默认最小高度（两行输入）。
///
/// 给一个下限是为了输入区被别处压缩时不至于退回成一条表单输入框的观感；
/// 内容更高时面板照常长高。浮窗里按一行算，见 [ChatComposer.visibleLines]。
const double kChatComposerMinHeight =
    _panelFixedHeight + _editorLineHeight * _defaultEditorLines;

/// 空闲折叠态（[ChatComposer.compactWhenIdle]）的面板高度。
///
/// 30（发送按钮的圆）+ 上下各 6 的内边距：折叠后只剩"「+」+ 输入框 + 发送"
/// 这一行，高度与控件本身同高，不再给第二行留位置。
///
/// 与 [kChatComposerMinHeight] 同一个口径：这里写的是内容 + 内边距，
/// 面板外框的 `Border.all(1)` 会让实测矩形再多 2。
const double kChatComposerCompactHeight = 42;

/// 输入面板本体的 Key。
///
/// 测试要量「+」到面板左边与下边的距离，需要一个恰好等于面板边界的东西：
/// `ChatComposer` 的外框还含着下面那行运行统计，拿来算会偏。
const Key kChatComposerPanelKey = Key('chat-composer-panel');

/// 输入面板：一块圆角容器把输入框和控件行包在一起。
///
/// 从 `chat_page.dart` 里拆出来：那个文件已经近千行，而输入面板与页面逻辑
/// 没有耦合（只吃 controller 与两个回调），搬出来才能放开手改视觉。
///
/// 面板下方的运行统计**不在这里**：那是页面级装饰，新会话居中时不出现，
/// 由调用方按需拼装。组件只管面板本体，才能同时放进居中列与贴底列。
class ChatComposer extends ConsumerStatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onStop,
    this.stopping = false,
    this.flowing = false,
    this.permission = ComposerDefaults.permission,
    this.onPermissionChanged,
    this.reasoning = ReasoningLevels.fallback,
    this.onReasoningChanged,
    this.contextTokens = 0,
    this.contextWindow = 0,
    this.compactedMessages = 0,
    this.compacting = false,
    this.onOpenCompaction,
    this.visibleLines = _defaultEditorLines,
    this.compactWhenIdle = false,
  });

  /// 空闲时把面板收成一行：只有「+」、输入框与发送按钮。
  ///
  /// 窄屏手机（iOS / Android）用它把输入区压到最小：没聚焦（系统键盘没弹出）
  /// 且没有草稿时只占一行，点进输入框或已有内容才展开成完整的两行 + 控件行。
  ///
  /// 默认关：桌面、宽屏与所有既有的测试 harness 仍是一套完整形态。
  final bool compactWhenIdle;

  /// 空输入时显示几行。
  ///
  /// 停靠 / 整页是两行；浮窗是小窗，收成一行把高度让给消息区（见 `chat_page` 的
  /// `_composerArea`）。这个值同时决定面板的最小高度，否则小窗里会留一块空。
  final int visibleLines;

  /// 富文本控制器：技能标签是文档里的一个 embed 节点。
  ///
  /// 输入栏的文本读写一律走 `composer_text.dart` 的助手，
  /// 调用方不要直接摸 [Document]。
  final QuillController controller;
  final bool sending;
  final VoidCallback onSend;

  /// 生成中点击停止。和发送是同一个按钮位的两副面孔，语义相反。
  final VoidCallback onStop;

  /// 已经点了停止、等服务端收尾：按钮换成小转圈并挡住连点。
  final bool stopping;

  /// 这一轮还在生成：面板边缘亮起霓虹流光。
  ///
  /// 不直接读 [sending] 是因为两者的生命周期不完全一样：会话页传的就是
  /// `sending`（含点停止后等服务端收尾那一段），而空态页的 `sending` 只是
  /// "正在建会话"，几百毫秒后就切页，那里的流光亮一下反而像闪屏。
  final bool flowing;

  /// 当前审批方式（`request` / `auto`）。状态由页面持有，这里只负责画。
  final String permission;

  /// 切换审批方式。不传就是只读展示。
  final ValueChanged<String>? onPermissionChanged;

  /// 推理等级当前值（`ReasoningLevels` 里的字符串）。
  final String reasoning;

  /// 切换推理等级。不传就是只读展示。
  final ValueChanged<String>? onReasoningChanged;

  /// 当前上下文长度（本轮最后一次模型调用的输入 token 数）。
  ///
  /// 由页面从最近一条 assistant 消息的 `usage.contextTokens` 取，
  /// 输入栏只负责画环；0 表示还没有用量可看。
  final int contextTokens;

  /// 当前模型的最大上下文窗口（tokens）。0 表示服务端没给。
  final int contextWindow;

  /// 已被整理成摘要的消息条数；0 表示没有可用摘要。
  ///
  /// 只进悬停提示里那一句"更早 N 条已压缩"，不参与环形占比。
  final int compactedMessages;

  /// 点上下文环打开摘要弹窗。`null` 表示没有压缩记录，环只作展示。
  final VoidCallback? onOpenCompaction;

  /// 正在手动整理上下文：环改成一段持续旋转的弧。
  final bool compacting;

  @override
  ConsumerState<ChatComposer> createState() => _ChatComposerState();
}

/// 光标前的 `@关键字`：`(行首或空白) + @ + 名字片段`。
final RegExp _mentionPattern = RegExp(r'(^|\s)@([A-Za-z0-9_-]*)$');

/// 候选最多列几条。再多就得滚，扫一眼的成本超过直接打完。
const int _maxCandidates = 8;

/// 候选上屏后多久内到达的 Enter 仍算"输入法在用"。
///
/// macOS 可能先把拼音替换成汉字、再把同一次 Enter 派给框架，这时组字区间
/// 已经为空，只能靠一个短窗口认出"这一下是上屏键"。窗口取小值：太长会把
/// 用户上屏后立刻按下的发送键也一起吞掉。
const Duration _imeCommitWindow = Duration(milliseconds: 300);

class _ChatComposerState extends ConsumerState<ChatComposer> {
  List<SkillInfo> _candidates = const <SkillInfo>[];
  int _highlight = 0;

  /// 编辑器自己的焦点节点。
  ///
  /// 需要显式持有，是因为候选面板的行是 `MenuItemButton`——点它会把焦点抢走，
  /// 选完之后必须还回来，否则用户得再点一下输入框才能继续打字。
  final FocusNode _focus = FocusNode();

  /// 编辑器自己的滚动控制器。必须由这里持有：`QuillEditor.basic` 每次
  /// build 都会新建一个，滚动位置会在每次重建时被丢掉。
  final ScrollController _editorScroll = ScrollController();

  /// 编辑器状态，只为读输入法组字区间。
  ///
  /// `QuillController` 不暴露 composing，组字区间挂在 raw editor 的
  /// `composingRange` 上；`QuillEditorConfig.editorKey` 是唯一能在外面拿到
  /// 它的入口（默认是内部自己建的 key，外部无从访问）。
  final GlobalKey<QuillRawEditorState> _editorKey =
      GlobalKey<QuillRawEditorState>();

  /// 上一次采样时输入法是否正在组字：用来捕捉"组字结束"那一刻。
  bool _wasImeComposing = false;

  /// 刚完成一次候选上屏，紧随其后的 Enter 属于输入法，不是发送。
  bool _imeCommitPending = false;

  /// [_imeCommitPending] 的复位定时器。
  Timer? _imeCommitTimer;

  /// 这轮组字里已有 Enter 判给输入法（没拿去发送）。
  ///
  /// 用来区分"上屏后就该复位"和"上屏那一下正是刚判给输入法的那次 Enter"：
  /// 后者若再开一个窗口，用户紧接着按的发送键会被多吞一次。
  bool _enterConsumedForIme = false;

  /// 候选面板挂在 `Overlay` 里。
  ///
  /// 为什么不用 `OverflowBox` / `Stack` + 负偏移：父级的命中测试会先判断
  /// "点击是否在自己尺寸内"，所以画到边界外的内容**永远收不到点击**——
  /// 表现是面板看得见、点不动，标签压根没进文档。
  /// `Overlay` 铺满全屏，溢出到输入栏上方的东西仍在它的范围里。
  final OverlayPortalController _panelOverlay = OverlayPortalController();

  /// 输入栏的位置（全局坐标），面板据此定位。
  final GlobalKey _anchorKey = GlobalKey();
  Offset _anchor = Offset.zero;

  /// 附件入口：粘贴、拖入、选择器三条路径共用这一份。
  ///
  /// 放在 State 里而不是上层传下来：它只吃 controller 与 API 客户端，
  /// 两者这里都能拿到；由上层装配会把 `ChatComposerArea` 变成 StatefulWidget，
  /// 而它现在是个纯外框。
  late final ComposerAttachmentIntake _intake = ComposerAttachmentIntake(
    controller: controller,
    // 上传是异步的，可能在切页之后才回来：那时 `ref` 已经不能用了，
    // 取不到客户端就按"服务未连接"处理，不该抛一个 dispose 异常。
    clientOf: () => mounted ? ref.read(apiClientProvider) : null,
    notify: _notify,
  );

  /// 有东西正悬在输入栏上方（系统文件或文件树里的路径）。只影响描边与提示。
  _ComposerDropKind? _drop;

  /// 粘贴快捷键正在处理中。Cmd+V 可能连发（长按），不加闸会贴出好几枚。
  bool _pasting = false;

  /// 编辑器当前是否有焦点（= 系统键盘是否弹出）。
  bool _hasFocus = false;

  /// 文档里有没有草稿。技能标签、路径引用、上传中的附件都算。
  bool _hasDraft = false;

  /// 折叠态只在「有焦点」或「有草稿」时展开。
  ///
  /// 不能只看 `_focus.hasFocus`：用户打完一句话、点到别处收键盘时，面板不该
  /// 把内容藏进一行里；也不能只看草稿：空输入点进输入框就得让权限 / 模型
  /// 两个胶囊出来。
  bool get _expanded => !widget.compactWhenIdle || _hasFocus || _hasDraft;

  /// 文档里有"任何东西"：正文、技能标签、附件（含上传中）、路径引用。
  ///
  /// 不复用 `composerHasContent`：那个只认已就绪的附件 id，上传中的芯片会被
  /// 判成空，面板就会在附件转圈时缩回一行、把芯片裁掉。
  bool get _draftNow =>
      composerText(controller).isNotEmpty ||
      skillEmbeds(controller).isNotEmpty ||
      attachmentEmbeds(controller).isNotEmpty;

  // 页面持有的状态在这里取一次，build 与 _controlRow 里沿用原字段名，
  // 改造不牵动布局代码。
  QuillController get controller => widget.controller;
  bool get sending => widget.sending;
  VoidCallback get onSend => widget.onSend;
  VoidCallback get onStop => widget.onStop;
  bool get stopping => widget.stopping;
  String get permission => widget.permission;
  ValueChanged<String>? get onPermissionChanged => widget.onPermissionChanged;

  @override
  void initState() {
    super.initState();
    controller.addListener(_syncCandidates);

    // 折叠判定只在"是 / 否"翻转时重建面板：输入过程中不能逐键重建整块面板
    // （三个菜单锚点都在里面），也不能漏掉"删空最后一个字符"这种回退。
    controller.addListener(_syncCompactState);
    _focus.addListener(_syncCompactState);
    // 初值要在挂监听之后取一次：空态页可能把一句话交接进来（`setComposerText`），
    // 那种情况下首帧就该是展开态。
    _hasDraft = _draftNow;

    // 预热技能清单：`atSkillsProvider` 是首次 `ref.read` 才开始加载的，
    // 等到用户打出 `@` 才去拉，第一下会读到空列表、候选不弹。
    ref.read(atSkillsProvider);
  }

  /// 焦点或"有无草稿"翻转时重建面板，让折叠态跟上。
  ///
  /// 每键都读一次文档是刻意的：只有它能捕捉"删空最后一个字符 → 该缩回一行"。
  /// 比对之后再 `setState`，所以一段连续输入只会重建两次。
  void _syncCompactState() {
    if (!mounted) {
      return;
    }
    final focus = _focus.hasFocus;
    final draft = _draftNow;
    if (focus == _hasFocus && draft == _hasDraft) {
      return;
    }
    setState(() {
      _hasFocus = focus;
      _hasDraft = draft;
    });
  }

  /// 编辑器外观。字号、行高、颜色全部取自设计 token，
  /// 与全站正文一致——否则输入的字和发出去的字看起来是两种东西。
  DefaultStyles _editorStyles(BuildContext context) {
    final palette = AppPalette.of(context);
    final body = TextStyle(
      fontSize: AppFontSize.base,
      height: AppLineHeight.normal,
      color: palette.text.primary,
    );

    return DefaultStyles(
      paragraph: DefaultTextBlockStyle(
        body,
        const HorizontalSpacing(0, 0),
        const VerticalSpacing(0, 0),
        const VerticalSpacing(0, 0),
        null,
      ),
      placeHolder: DefaultTextBlockStyle(
        body.copyWith(color: palette.text.tertiary),
        const HorizontalSpacing(0, 0),
        const VerticalSpacing(0, 0),
        const VerticalSpacing(0, 0),
        null,
      ),
    );
  }

  @override
  void dispose() {
    controller.removeListener(_syncCandidates);
    controller.removeListener(_syncCompactState);
    _focus.removeListener(_syncCompactState);
    _imeCommitTimer?.cancel();
    _editorScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 输入法是否正在组字（拼音串还没上屏）。
  ///
  /// 组字期间物理按键照样会派给框架，Enter 会被当成"发送"，因此每个 Enter
  /// 入口都要先过这一关。
  bool get _imeComposing {
    final range = _editorKey.currentState?.composingRange.value;
    return range != null && range.isValid && !range.isCollapsed;
  }

  /// 这一下 Enter 归输入法时，返回该交给 quill 与平台的结论；不归输入法返回 null。
  ///
  /// 两种"归输入法"的处理不一样，区别是本次修复的核心：
  /// - **组字中**（拼音串还没上屏）：必须让回车回到平台、交给输入法选词与上屏。
  ///   `KeyEventResult.handled` 会把按键从平台链路上摘掉，输入法再也看不到回车、
  ///   候选词选不了；`skipRemainingHandlers` 才是"框架不认领，但别让编辑器和
  ///   外层快捷键处理"——回车照常上屏、quill 不插换行、外层不会发送。
  /// - **刚上屏**（引擎先上屏再把同一次按键派过来）：输入法这一下已经做完了，
  ///   直接 `handled` 吞掉，避免回传平台后又被当成一次换行。
  ///
  /// 组字中命中要记账：等会儿组字区间归零时不能再开窗口（那是同一次按键，
  /// 见 [_trackIme]），否则用户紧接着按的发送会被多吞一次。
  KeyEventResult? _imeEnterResult() {
    if (_imeComposing) {
      _enterConsumedForIme = true;
      return KeyEventResult.skipRemainingHandlers;
    }
    if (_imeCommitPending) {
      _imeCommitPending = false;
      return KeyEventResult.handled;
    }
    return null;
  }

  /// 采样组字状态，捕捉"组字 → 上屏"的转换。
  ///
  /// 挂在 controller 的监听里（[_syncCandidates]）而不是 `composingRange` 上：
  /// quill 的 `updateEditingValue` 先同步组字区间、再改文档，所以文档通知
  /// 到达时读到的已是最新值，不必再注册一个监听器、也不必管它的生命周期。
  void _trackIme() {
    if (_imeComposing) {
      _wasImeComposing = true;
      return;
    }
    if (!_wasImeComposing) {
      return;
    }
    _wasImeComposing = false;

    // 这次上屏正是刚才被吞下的那次 Enter 造成的：那一下已经算用掉了，
    // 再开窗口会把它后面那次真正的发送也吞掉。
    if (_enterConsumedForIme) {
      _enterConsumedForIme = false;
      return;
    }

    _imeCommitPending = true;
    _imeCommitTimer?.cancel();
    _imeCommitTimer = Timer(_imeCommitWindow, () {
      _imeCommitPending = false;
    });
  }

  /// 光标前是 `@关键字` 就刷新候选，否则收起面板。
  void _syncCandidates() {
    _trackIme();

    // 用 `toPlainText()` 而不是 `document` 自身：它的下标与
    // `selection.baseOffset` 是同一套坐标（每个 embed 占一个 `\uFFFC`）。
    final text = controller.document.toPlainText();
    final offset = controller.selection.baseOffset;

    if (offset < 0 || offset > text.length) {
      _clearCandidates();
      return;
    }

    final match = _mentionPattern.firstMatch(text.substring(0, offset));
    if (match == null) {
      _clearCandidates();
      return;
    }

    final query = (match.group(2) ?? '').toLowerCase();
    final skills = ref.read(atSkillsProvider).value ?? const <SkillInfo>[];
    final filtered = skills
        .where(
          (skill) =>
              query.isEmpty ||
              skill.name.toLowerCase().contains(query) ||
              skill.description.toLowerCase().contains(query),
        )
        .take(_maxCandidates)
        .toList(growable: false);

    if (filtered.isEmpty) {
      _clearCandidates();
      return;
    }

    // 面板在 Overlay 里，位置得自己算：输入栏左上角的全局坐标。
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      _anchor = box.localToGlobal(Offset.zero);
    }

    setState(() {
      _candidates = filtered;
      if (_highlight >= filtered.length) {
        _highlight = 0;
      }
    });
    if (!_panelOverlay.isShowing) {
      _panelOverlay.show();
    }
  }

  void _clearCandidates() {
    if (_panelOverlay.isShowing) {
      _panelOverlay.hide();
    }
    if (_candidates.isEmpty) {
      return;
    }
    setState(() {
      _candidates = const <SkillInfo>[];
      _highlight = 0;
    });
  }

  void _moveHighlight(int delta) {
    if (_candidates.isEmpty) {
      return;
    }
    setState(() {
      _highlight = (_highlight + delta) % _candidates.length;
      if (_highlight < 0) {
        _highlight += _candidates.length;
      }
    });
  }

  /// 把光标前的 `@片段` 换成技能标签。
  ///
  /// 标签是文档里的节点，不是一段文字：用户能继续在它前后输入，
  /// 它会随文本换行流动，退格也会整体删掉。
  void _select(SkillInfo skill) {
    final text = controller.document.toPlainText();
    final offset = controller.selection.baseOffset;
    final match = offset >= 0 && offset <= text.length
        ? _mentionPattern.firstMatch(text.substring(0, offset))
        : null;

    // 先把 `@片段` 删掉，标签就落在它原来的位置。
    if (match != null) {
      // 前缀里可能有一个空白（`^|\s`），真正要删的是 `@` 之后那一段。
      final start = match.start + (match.group(1)?.length ?? 0);
      controller.replaceText(
        start,
        offset - start,
        '',
        TextSelection.collapsed(offset: start),
      );
    }

    insertSkillEmbed(controller, skill);
    _clearCandidates();

    // 面板的行是 `MenuItemButton`，点它会把焦点抢去行上；
    // 选完立刻还回来，用户才能接着打字。
    _focus.requestFocus();
  }

  /// 候选面板按技能名回选。
  ///
  /// `AgentMenuPanel` 只回传 `value`，而插入标签需要完整的 `SkillInfo`
  /// （名称之外的说明、来源都要用），所以在这里回查一次。
  void _selectByName(String name) {
    if (_candidates.isEmpty) {
      return;
    }
    final skill = _candidates.firstWhere(
      (item) => item.name == name,
      orElse: () => _candidates.first,
    );
    _select(skill);
  }

  /// 一句话提示：容量超限、上传失败这类"用户需要知道但要能继续用"的消息。
  void _notify(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  /// 「+」菜单里的两个附件入口。
  ///
  /// `file` 是系统文件选择器；`paste` 只在移动端出现（那里没有 Cmd/Ctrl+V
  /// 的按键事件，系统粘贴也带不出图片字节）。
  void _onAttachAction(String action) {
    switch (action) {
      case 'file':
        unawaited(_intake.pickFiles());
      case 'paste':
        unawaited(_intake.pasteImage());
    }
  }

  /// Cmd/Ctrl+V：剪贴板里是图片就落一枚芯片，否则交给编辑器自己粘文字。
  ///
  /// 这里必须"先不接管、后补动作"：`onKeyPressed` 是同步回调，读剪贴板是异步的，
  /// 拿不到结果就没法决定是否吞掉这次按键。于是照常返回 null 让 quill 粘文字，
  /// 同时起一个异步读取；读到的若是纯图片（没有文字），再补一枚芯片。
  void _handlePasteShortcut() {
    if (_pasting) {
      return;
    }
    _pasting = true;
    unawaited(
      _intake.pasteFromShortcut().whenComplete(() => _pasting = false),
    );
  }

  /// 拖入开始/结束：只换外观，不改尺寸，否则面板会在拖动中跳一下。
  ///
  /// `onWillAccept` 会在指针移动时反复触发，同值直接返回，避免每帧重建面板。
  void _setDrop(_ComposerDropKind? kind) {
    if (_drop == kind) {
      return;
    }
    setState(() => _drop = kind);
  }

  /// Enter：候选打开时选中候选，否则发送。
  ///
  /// 内层 `onKeyPressed` 与外层 `CallbackShortcuts` 共用这一份实现，
  /// 谁先接住都走同一条路，不会出现"两处各写一半、行为不一致"。
  void _handleEnter() {
    // 输入法的 Enter（组字中选词、候选上屏）不属于发送。
    if (_imeEnterResult() != null) {
      return;
    }
    if (_candidates.isNotEmpty) {
      _select(_candidates[_highlight.clamp(0, _candidates.length - 1)]);
      return;
    }
    if (sending) {
      return;
    }
    onSend();
  }

  /// 编辑器里的按键：Enter 发送、候选面板的 ↑↓ / Enter / Esc。
  ///
  /// 挂在 quill 的 `onKeyPressed` 上，是因为它在 `EditorKeyboardShortcuts`
  /// 里**最先**被调用，早于编辑器的光标移动与换行处理。放在外层
  /// `Shortcuts` 里不行：方向键会先被编辑器吃掉，候选高亮不动、光标却在跑。
  ///
  /// 返回 `null` 表示"不接管"，交回编辑器默认行为（换行、光标移动等）。
  KeyEventResult? _onEditorKey(KeyEvent event, Node? node) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return null;
    }

    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final withShift = HardwareKeyboard.instance.isShiftPressed;

    // Cmd/Ctrl+V：顺手检查剪贴板里有没有图片。不吞这次按键——
    // 剪贴板里是文字时，编辑器自己的粘贴路径要照常走。
    final isPaste = key == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed);
    if (isPaste) {
      _handlePasteShortcut();
      return null;
    }

    // 输入法在用这个 Enter（组字中选词、或刚上屏）：既不能发送，
    // 也不能让编辑器插入换行。macOS 组字期间物理按键照样会派到框架，
    // 所以必须在这里抢在编辑器与发送之前给出结论；组字中返回的是
    // `skipRemainingHandlers`，回车仍会回到平台交给输入法（见 [_imeEnterResult]）。
    if (isEnter) {
      final ime = _imeEnterResult();
      if (ime != null) {
        return ime;
      }
    }

    if (_candidates.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveHighlight(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveHighlight(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _clearCandidates();
        return KeyEventResult.handled;
      }
      if (isEnter && !withShift) {
        // 候选打开时 Enter 是"选中技能"，不是发送。
        _select(_candidates[_highlight.clamp(0, _candidates.length - 1)]);
        return KeyEventResult.handled;
      }
    }

    if (isEnter && !withShift) {
      if (!sending) {
        onSend();
      }
      return KeyEventResult.handled;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 浅色主题下面板要比页面更白（页面是 surface），才像一张浮起来的纸；
    // 深色主题反过来，用略亮于背景的容器色表达层级。都不写死白色。
    final panelColor = theme.brightness == Brightness.light
        ? scheme.surfaceContainerLowest
        : scheme.surfaceContainerHigh;
    // 清单变化时无条件重算：用户可能已经打完 `@片段` 了（值晚到要补出候选），
    // 也可能正开着面板（设置页刚改过技能包，旧列表不能继续挂着）。
    // 重算本身会处理"没有 `@` 上下文就收起面板"与重新过滤，不必在这里判空。
    ref.listen(atSkillsProvider, (_, next) {
      if (next.hasValue) {
        _syncCandidates();
      }
    });

    // 占位提示的样式在 `_editorStyles` 里：走第三档文字色，
    // 比正文淡一档，但任何底色上都 ≥ 4.5:1。

    // 候选面板挂在 Overlay 里，位置由 `_anchor` 自己算。
    //
    // 两个约束同时成立才需要这么绕：面板不能占布局高度（否则新会话页的
    // 「品牌行 + 输入栏」整块变高、中心不变，输入栏会被顶下去），又必须
    // 能收到点击。普通布局方案（`OverflowBox`、`Stack` 加负偏移）都会在
    // 父级的命中测试里先判断"点击是否在自己尺寸内"，画到边界外的部分
    // 收不到点击——表现是面板看得见、点不动，标签压根没进文档。

    // 折叠态：窄屏手机空闲时只留一行（见 [ChatComposer.compactWhenIdle]）。
    final compact = !_expanded;

    return OverlayPortal(
      controller: _panelOverlay,
      overlayChildBuilder: (context) {
        if (_candidates.isEmpty) {
          return const SizedBox.shrink();
        }
        // 挂在 Overlay 里：既不占布局高度，也不会被父级的命中边界裁掉。
        // `FractionalTranslation` 把面板上移自身高度，底边正好落在输入栏顶边。
        return Positioned(
          left: _anchor.dx,
          top: _anchor.dy,
          child: FractionalTranslation(
            translation: const Offset(0, -1),
            child: Padding(
              // 浮层与输入栏之间留 8dp。
              padding: const EdgeInsets.only(bottom: 8),
              child: TapRegion(
                onTapOutside: (_) => _clearCandidates(),
                child: AgentMenuPanel<String>(
                  width: kComposerSkillMenuWidth,
                  groups: <AgentMenuGroup<String>>[
                    AgentMenuGroup<String>(
                      items: <AgentMenuItem<String>>[
                        for (
                          var index = 0;
                          index < _candidates.length;
                          index += 1
                        )
                          AgentMenuItem<String>(
                            value: _candidates[index].name,
                            label: '@${_candidates[index].name}',
                            description: _candidates[index].description,
                            // 这一行是"键盘停在哪"，命令行靠它点亮底色。
                            selected: index == _highlight,
                          ),
                      ],
                    ),
                  ],
                  onSelected: _selectByName,
                ),
              ),
            ),
          ),
        );
      },
      // 锚点包一层 `KeyedSubtree`：`Container` 自己的 key 要给测试量尺寸。
      child: KeyedSubtree(
        key: _anchorKey,
        child: _withDropTarget(
          // 流光只画不占位：包在面板外层，`Container` 的 key、尺寸与内边距
          // 都不动，拖动目标也仍是同一块矩形。
          child: ComposerFlowBorder(
            // 拖动高亮优先：拖入时用户要看的是"松手会落在哪"，不是生成状态。
            active: widget.flowing && _drop == null,
            radius: _panelRadius,
            child: Container(
              key: kChatComposerPanelKey,
              decoration: BoxDecoration(
                color: panelColor,
                borderRadius: BorderRadius.circular(_panelRadius),
                // 拖动中把描边换成主色：不改内边距、不改尺寸，面板不会跳一下。
                // 流光激活时让出这 1dp：宽度必须留着（几何不能变），
                // 只把颜色换成透明，否则灰线会从 2dp 渐变边下面露出来。
                border: Border.all(
                  color: _drop != null
                      ? scheme.primary
                      : widget.flowing
                      ? Colors.transparent
                      : scheme.outlineVariant.withValues(alpha: 0.6),
                  width: _drop != null ? 1.5 : 1,
                ),
                // 极淡的一层投影：面板浮在内容之上，但别压出一圈灰边。
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.05),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              // 左 8 与下 8 相等：控件行底对齐后，「+」到左边和下边的距离一致。
              // 输入文字的左内边距由 `TextField.contentPadding` 单独补回来。
              // 折叠态上下收到 6：面板只剩一行，10 / 8 不对称的留白会显得下重。
              padding: compact
                  ? const EdgeInsets.fromLTRB(8, 6, 10, 6)
                  : const EdgeInsets.fromLTRB(8, 10, 10, 8),
              constraints: BoxConstraints(
                minHeight: compact
                    ? kChatComposerCompactHeight
                    : _panelFixedHeight +
                          _editorLineHeight * widget.visibleLines,
              ),
              child: Stack(
                // `passthrough`：不能把最小高度约束在 Stack 里丢掉，
                // 否则拖动提示一出现，面板会缩到自己内容的高度。
                fit: StackFit.passthrough,
                children: <Widget>[
                  if (compact)
                    _compactRow(context)
                  else
                    _panelContent(context),
                  // 拖动提示：只在拖动中出现；`IgnorePointer` 保证它不吃拖放事件。
                  // 用 `Positioned` 而不是插进 Column：提示不该改变面板高度。
                  if (_drop != null)
                    Positioned(
                      right: 4,
                      top: 0,
                      child: IgnorePointer(
                        child: Text(
                          _drop == _ComposerDropKind.files
                              ? '松开以添加附件'
                              : '松开以引用文件',
                          style: AppText.of(context).meta.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 把面板变成拖放目标。
  ///
  /// 两条通道互不相干：
  /// - [DragTarget]：Flutter 内部的拖拽，目前只有文件树的行（路径引用）；
  /// - `DropTarget`：系统文件管理器拖进来的真实文件，只有桌面三端有。
  ///
  /// 移动端即使挂上 `DropTarget` 也收不到事件，反而多一层手势层，所以那里只留
  /// [DragTarget]——文件树拖引用在触摸端同样成立。
  Widget _withDropTarget({required Widget child}) {
    final droppable = DragTarget<ProjectPathReference>(
      onWillAcceptWithDetails: (_) {
        _setDrop(_ComposerDropKind.pathRef);
        return true;
      },
      onLeave: (_) {
        // 只复位自己那一种：系统文件拖入时这里不该把高亮关掉。
        if (_drop == _ComposerDropKind.pathRef) {
          _setDrop(null);
        }
      },
      onAcceptWithDetails: (details) {
        _setDrop(null);
        insertPathRefEmbed(controller, details.data);
        // 松手后把焦点还给输入区：拖完就能接着打字。
        _focus.requestFocus();
      },
      // 高亮由 `_drop` 驱动，候选列表这里用不上。
      builder: (context, candidateData, rejectedData) => child,
    );

    if (!_supportsFileDrop) {
      return droppable;
    }
    return DropTarget(
      onDragEntered: (_) => _setDrop(_ComposerDropKind.files),
      onDragExited: (_) => _setDrop(null),
      onDragDone: (details) {
        _setDrop(null);
        unawaited(_intake.addDropped(details));
      },
      child: droppable,
    );
  }

  /// 展开态：输入区在上、控件行在下。
  ///
  /// 与折叠态共用同一个 [QuillEditor]、同一份 controller 与 focus node，
  /// 形态切换只换外层排布，草稿、光标与滚动位置都不动。
  Widget _panelContent(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      // 被最小高度撑出来的余量分到中间：文字贴顶、控件贴底。
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        _editor(context, compact: false),
        const SizedBox(height: 6),
        _controlRow(context),
      ],
    );
  }

  /// 折叠态：一行里装下「+」、输入框与发送按钮。
  ///
  /// 权限与模型胶囊在这里让位：窄屏手机的面板只有一行高，两枚胶囊会把输入框
  /// 挤到几乎没有宽度。点进输入框即展开，那时它们照常出现。
  Widget _compactRow(BuildContext context) {
    return Row(
      children: <Widget>[
        ComposerAttachButton(onSelected: _onAttachAction),
        const SizedBox(width: 6),
        Expanded(child: _editor(context, compact: true)),
        const SizedBox(width: 6),
        _sendButton(),
      ],
    );
  }

  /// 输入区：富文本编辑器。技能标签与附件芯片都是文档里的节点，
  /// 能随文字换行流动，也能被退格整体删掉。
  ///
  /// [compact] 是折叠态：只占一行高，占位文案也收短——"发送消息；@ 技能派任务"
  /// 在一行里会被截成半句，看起来像被裁掉了。
  Widget _editor(BuildContext context, {required bool compact}) {
    return Padding(
      // 左 6 是补回面板左内边距从 14 收到 8 的那 6dp：
      // 文字仍距面板左沿 14，与参考图的缩进一致。
      padding: compact
          ? const EdgeInsets.only(left: 6)
          : const EdgeInsets.only(left: 6, top: 4, bottom: 4),
      // 双保险：内层 `onKeyPressed` 能被 quill 最先回调，外层这套
      // 在它漏掉的键上兜底。任何一层接住都走同一份实现，
      // 不会出现两套语义。
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): _handleEnter,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): _handleEnter,
          if (_candidates.isNotEmpty) ...<ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                _moveHighlight(-1),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _moveHighlight(1),
            const SingleActivator(LogicalKeyboardKey.escape): _clearCandidates,
          },
        },
        child: QuillEditor(
          controller: controller,
          focusNode: _focus,
          scrollController: _editorScroll,
          config: QuillEditorConfig(
            // 把编辑器状态暴露出来，才能判断输入法是否在组字
            // （`QuillController` 上没有 composing）。
            editorKey: _editorKey,
            placeholder: compact ? '发送消息' : '发送消息；@ 技能派任务',
            padding: EdgeInsets.zero,
            // 按 [ChatComposer.visibleLines] 起步、最多 6 行：
            // 超过后编辑器内部滚动，不会把输入栏撑满整屏。
            // 折叠态固定一行：多出来的内容不可能出现（有内容就会展开）。
            minHeight: _editorLineHeight * (compact ? 1 : widget.visibleLines),
            maxHeight: _editorLineHeight * (compact ? 1 : _maxEditorLines),
            expands: false,
            scrollable: true,
            embedBuilders: <EmbedBuilder>[
              const SkillEmbedBuilder(),
              // 附件芯片的 X 要同时清文档与服务端那份：
              // 文档由 builder 自己删，服务端交给入口。
              AttachmentEmbedBuilder(
                onRemoved: (embed) => unawaited(_intake.discard(embed)),
              ),
              // 路径引用没有服务端那份，删掉节点就完事。
              const PathRefEmbedBuilder(),
            ],
            customStyles: _editorStyles(context),
            // 明知是 experimental 仍要用：quill 没有第二个"在编辑器
            // 处理方向键之前"的稳定入口。声明处写了返回 null 即交回
            // 默认行为，语义清楚；升级若改签名，这里会直接编译失败，
            // 不会静默退化成"↑↓ 不动高亮、光标乱跑"。
            // ignore: experimental_member_use
            onKeyPressed: _onEditorKey,
          ),
        ),
      ),
    );
  }

  /// 发送 / 停止按钮。
  ///
  /// 唯一依赖输入内容的部分：只让它跟着 controller 重建，
  /// 整块面板（含三个菜单锚点）不再逐键重建。
  Widget _sendButton() {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _SendButton(
        // 只发附件不写文字也是完整意图；但还有附件在传时不能发——
        // 那一刻发出去，服务端拿不到 id，附件会静默丢掉。
        enabled:
            !sending &&
            composerHasContent(controller) &&
            pendingAttachmentCount(controller) == 0,
        sending: sending,
        stopping: stopping,
        onSend: onSend,
        onStop: onStop,
      ),
    );
  }

  /// 控件行：左侧「+」与权限胶囊，右侧模型胶囊与发送按钮。
  ///
  /// 底对齐：24 高的「+」与两个胶囊贴到行底，于是它们到面板下沿的距离
  /// 就等于面板的 `padding.bottom`，和左边距 8 一样，四个角看起来才匀。
  Widget _controlRow(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        ComposerAttachButton(onSelected: _onAttachAction),
        const SizedBox(width: 6),
        // 两个胶囊都兜一个宽度上限：它们内部的文案要靠 `Flexible` 省略，
        // 而 `Flexible` 在无界约束下会直接抛断言（控件行里的非 flex 子项
        // 拿到的正是无界宽度）。
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: ComposerPermissionMenu(
            value: permission,
            onSelected: onPermissionChanged,
          ),
        ),
        const SizedBox(width: 8),
        // 剩余宽度全给模型胶囊，靠右下对齐：空间富余时它只占内容宽度，
        // 窗口窄到放不下时才收缩、把模型名截断。
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.bottomEnd,
            child: ComposerModelMenu(
              reasoning: widget.reasoning,
              onReasoningChanged: widget.onReasoningChanged,
            ),
          ),
        ),
        // 上下文占比环：紧贴模型胶囊右侧，读数与「这一轮用了多少上下文」同源。
        // 新会话 / 首轮还没收尾时没有用量，整枚环与它的前置间距一起不出现——
        // 否则模型胶囊和发送按钮之间会空出一段没有含义的留白。
        // 折叠态没有模型胶囊，也就不放它——那里横向空间只够输入框。
        if (widget.contextTokens > 0) ...<Widget>[
          const SizedBox(width: 8),
          ContextUsageRing(
            contextTokens: widget.contextTokens,
            contextWindow: widget.contextWindow,
            compactedMessages: widget.compactedMessages,
            compacting: widget.compacting,
            onOpenCompaction: widget.onOpenCompaction,
          ),
        ],
        const SizedBox(width: 8),
        _sendButton(),
      ],
    );
  }
}

/// 圆形发送按钮，三态：
///
/// - 空闲：上箭头，输入为空时灰底不可点；
/// - 生成中：主色实心圆 + 白色圆角方块，点它是**停止**；
/// - 停止中：小号转圈，等服务端收尾，挡掉连点。
///
/// 生成中把"能不能发"和"能不能停"压进同一个位置，是跟随参考产品的做法：
/// 一个按钮只表达"此刻最重要的一件事"，比并排两个更不容易点错。
///
/// 用 `Material` + `InkWell(customBorder: CircleBorder())` 而不是 `IconButton`：
/// 后者的水波纹是方形命中区，在这块圆角面板里会溢出一圈直角。
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.sending,
    required this.stopping,
    required this.onSend,
    required this.onStop,
  });

  final bool enabled;
  final bool sending;
  final bool stopping;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 生成中即使输入框是空的，按钮也是"活"的：它现在是停止键。
    final active = sending || enabled;
    final foreground = active
        ? scheme.onPrimary
        : AppPalette.of(context).text.disabled;

    final VoidCallback? onTap = sending
        ? (stopping ? null : onStop)
        : (enabled ? onSend : null);

    return Tooltip(
      message: sending ? (stopping ? '正在停止' : '停止生成') : '发送',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: active
              ? <BoxShadow>[
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: active
              ? scheme.primary
              : scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 30,
              height: 30,
              child: Center(
                child: _content(scheme: scheme, foreground: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content({required ColorScheme scheme, required Color foreground}) {
    if (stopping) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
      );
    }
    if (sending) {
      // 白色圆角方块：与参考图一致，也避开 Material 的 stop 图标偏圆的问题。
      return Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: foreground,
          borderRadius: BorderRadius.circular(2.5),
        ),
      );
    }
    return Icon(Icons.arrow_upward, size: 16, color: foreground);
  }
}
