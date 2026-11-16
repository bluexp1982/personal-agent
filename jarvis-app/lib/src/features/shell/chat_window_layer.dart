import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/app_tokens.dart';
import '../../core/project_providers.dart';
import '../conversations/chat_page.dart';
import '../conversations/conversations_page.dart';
import 'chat_window_state.dart';
import 'file_pane_state.dart';
import 'shell_geometry.dart';
import 'shell_layout_state.dart';

/// 缩放热区的厚度。
///
/// 10dp 是"鼠标够得到"与"不吃掉正文可点区域"的折中：再薄，指针要贴着边找
/// （8dp 时用户反馈"悬停半天没反应"）；再厚，左边缘会盖住输入框左侧的按钮
/// （输入栏自身有 16dp 内边距，10dp 仍留出 6dp）。
const double _kResizeEdge = 10;

/// 角上热区的边长。比边缘厚一档：两个方向共用一个手势，命中面积要够大。
const double _kResizeCorner = 20;

/// 聊天窗口层：会话视图在这个应用里唯一的宿主。
///
/// 它挂在骨架的 `ShellDividers` 内、索引固定，**同一时刻只有一份** `ChatPane`：
/// - 停靠：矩形等于中栏矩形（由 [railTaken] 与右栏状态算出，不测量、不差像素）；
/// - 浮窗：矩形等于用户拖出来的位置与尺寸；
/// - 窄屏：铺满整窗（不是销毁重挂——窗口拉窄再拉宽，消息与流必须还在）。
///
/// 为什么不在中栏与浮窗各放一份：两份实例就是两条 SSE、两套消息与轮询，
/// 必然分叉；而用 `GlobalKey` 在父级之间搬 State，Flutter 依旧会重建。
/// 所以"换形态"从头到尾只改外层的矩形与装饰。
class ChatWindowLayer extends ConsumerStatefulWidget {
  const ChatWindowLayer({
    super.key,
    required this.viewport,
    required this.wide,
    required this.railTaken,
    required this.fill,
  });

  /// 聊天窗口可用的整块区域（`SafeArea` 之内）。
  final Size viewport;

  /// 是否宽屏三栏布局。窄屏没有中栏可停靠，浮窗铺满整窗。
  final bool wide;

  /// 左栏连同它右侧拖动条占掉的宽度；左栏收起时为 0。
  final double railTaken;

  /// 右栏全屏 / 终端沉浸：中栏被吃掉，停靠无处可停。
  final bool fill;

  @override
  ConsumerState<ChatWindowLayer> createState() => _ChatWindowLayerState();
}

class _ChatWindowLayerState extends ConsumerState<ChatWindowLayer> {
  /// 手势期间的临时矩形。非 null 表示正在拖 / 缩放。
  ///
  /// 拖动**不写 provider**：每帧写一次会重建整个 `HomeShell`（终端、面板跟着
  /// 重绘），而位置只是这一个浮窗的事。松手时才把最终矩形交回状态层。
  Rect? _liveRect;

  /// 本次手势的起点矩形与累计位移。
  ///
  /// 位移必须自己累计：`DragUpdateDetails.delta` 是"这一帧走了多少"，
  /// 拿起点矩形 + 单帧位移会把前面的位移全部丢掉。
  Rect? _gestureBase;
  Offset _dragOffset = Offset.zero;

  bool _dragging = false;
  bool _resizing = false;

  /// 正在拉的是哪条边 / 哪个角。决定位移怎么换算成矩形，也决定拖动期间
  /// 全窗保底光标长什么样。
  _ResizeEdge _resizeEdge = _ResizeEdge.bottomRight;

  /// 形态切换的那段过渡。只在切换后的一小段时间里为 true：
  /// 它为 true 时 `AnimatedPositioned` 用 220ms 缓动，否则用 0（严格跟手、
  /// 窗口 resize 时也不会拖着一条延迟的尾巴）。
  bool _animating = false;

  /// 缓存的 `ChatPane` 实例。
  ///
  /// 拖动时每帧 `setState` 会重建这一层，如果每次都 `ChatPage(...)` 构造新
  /// widget，消息列表的 build 会跟着每帧跑一遍（长会话下很贵）。复用同一个
  /// 实例时 Flutter 的 `updateChild` 会直接跳过这棵子树。
  Widget? _paneCache;
  String? _paneCacheKey;

  /// 会话页的锚点。
  ///
  /// 必须是 `GlobalKey` 而不是 `ValueKey`：停靠 ⇄ 浮窗时外层包装会变
  /// （圆角、投影、拖拽热区的增删），`ValueKey` 只能在同一父级下复用 Element，
  /// 父级稍有不同整棵子树就会重建，消息、流式回答、滚动与草稿全部重来。
  /// `GlobalKey` 允许 Element 跨父级迁移，形态怎么变都还是同一个会话页。
  ///
  /// 换会话时必须换一枚新 key：同一个 GlobalKey 不能同时描述两段对话。
  GlobalKey _paneAnchor = GlobalKey(debugLabel: 'chat-pane');
  String? _paneAnchorConversationId;

  /// 最近一次布局用的宽度分配。
  ///
  /// 手势开始时要还原"现在这个矩形"，那时不在 build 里、也不能 watch，
  /// 所以把上一帧算好的那份存下来。手势永远发生在布局之后，这里的值不会过期。
  ShellColumns? _columns;

  @override
  void didUpdateWidget(ChatWindowLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fill && !widget.fill) {
      // 退出全屏：全屏期间的临时露面状态归位，免得下次进全屏又自己冒出来。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(chatWindowProvider.notifier).clearPeek();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final window = ref.watch(chatWindowProvider);
    final target = ref.watch(shellTargetProvider);
    // 宽度分配与 `_WideContent` 共用同一个纯函数：停靠矩形必须与中栏**逐像素一致**，
    // 否则左侧或右侧会露出一条背景色。
    final columns = resolveShellColumns(
      viewportWidth: widget.viewport.width,
      railTaken: widget.railTaken,
      paneVisible: ref.watch(filePaneVisibleProvider),
      paneWidth: ref.watch(filePaneWidthProvider),
      fill: widget.fill,
    );

    // 形态切换：让下一帧的位移走动画。这里不能直接在 build 里改状态，
    // 只置自己的标志位即可。
    ref.listen<bool>(
      chatWindowProvider.select((state) => state.floating),
      (previous, next) {
        if (previous == next || !mounted) {
          return;
        }
        setState(() => _animating = true);
      },
    );

    // 单一来源：浮窗期间只认 pinned（中栏这时已经让给项目 / 任务），
    // 停靠态认中栏当前选中的会话。
    final chat = window.floating
        ? window.pinned
        : (target is ConversationTarget ? target : null);

    // 浮窗期间从侧栏点了**另一个**会话：用户要的是"在中栏打开它"，
    // 自动停靠，避免出现两个聊天窗口。同一个会话不算（那是刚缩小的那一帧）。
    if (window.floating &&
        target is ConversationTarget &&
        target.conversationId != window.pinned?.conversationId) {
      final controller = ref.read(chatWindowProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dock();
      });
    }

    if (chat == null) {
      return const SizedBox.shrink();
    }

    _columns = columns;

    // 右侧栏全屏 / 终端沉浸时，聊天窗口默认让位：那一屏的语义是"这一栏独占"，
    // 再压一块浮窗上去等于把刚放大的内容又切掉一角。
    // 想看对话就用面板工具条里的「聊天浮窗」按钮把它叫出来（见 `ProjectPanel`）。
    final fullscreen = widget.fill;
    final peek = fullscreen && window.peekInFullscreen;
    final visible = !fullscreen || peek;

    // 全屏里叫出来的那块一定按浮窗渲染：中栏这时根本不存在；
    // 但**不改** `floating` 状态，退出全屏后要回到用户原来那种形态。
    final floating = window.floating || fullscreen;
    // 窄屏没有"浮窗"这种形态：没有中栏可停靠，小窗只会铺满整块屏幕，
    // 剩下的只是浮窗那套页头（停靠 / … / 关闭小窗），对手机没有意义。
    // 所以窄屏铺满时按**整页**画（返回箭头 + 标题 + 更多），与路由推上来的
    // 会话页完全一致；状态里的 `floating` 不动，拉宽回来仍是原来的小窗。
    final presentation = !widget.wide
        ? ChatPresentation.page
        : floating
        ? ChatPresentation.floating
        : ChatPresentation.docked;
    // 窄屏铺满整窗、以及全屏时被隐藏的那一份，都不画圆角与投影。
    final decorated =
        widget.wide && (window.floating || peek);
    // 只解析一次：四个参数各算一遍等于把 clamp 走四遍，也让"这一帧到底在哪个
    // 矩形"分散在四处。
    final rect = _resolveRect(window, floating: floating);

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: <Widget>[
        AnimatedPositioned(
          duration: _animating && !_dragging && !_resizing
              ? kChatFloatDuration
              : Duration.zero,
          curve: Curves.easeOutCubic,
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          onEnd: _handleAnimationEnd,
          // 全屏时只"藏起来"，不拆掉：`maintainState` 保住消息、流式回答、
          // 滚动位置与输入草稿，退出全屏 / 再次叫出来时原地接着走。
          child: Visibility(
            visible: visible,
            maintainState: true,
            maintainAnimation: true,
            child: _window(
              context,
              chat: chat,
              presentation: presentation,
              decorated: decorated,
            ),
          ),
        ),
        // 拖动 / 缩放期间盖一层全窗光标：指针一旦离开那 40dp 的栏头或
        // 16dp 的角，光标就会掉回箭头，看起来像"操作已经结束"。
        // `translucent` 只抢光标不抢事件。
        if (_dragging || _resizing)
          Positioned.fill(
            child: MouseRegion(
              // 拖动期间光标跟着手势走：拖左边是左右箭头、拖底边是上下箭头，
              // 拉到角上才是斜向。指针移出那 8dp 也不会掉回箭头。
              cursor: _resizing
                  ? _resizeEdge.cursor
                  : SystemMouseCursors.grabbing,
              hitTestBehavior: HitTestBehavior.translucent,
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }

  /// 当前应当渲染的矩形。
  ///
  /// [floating] 是"这一帧按哪种形态画"，而不是 `window.floating`：
  /// 面板全屏里被叫出来的浮窗、以及窄屏铺满，都属于"按浮窗画但状态里不是浮窗"。
  /// 两者混用会让松手后的落点被 [resolveFloatRect] 的默认值覆盖回去——
  /// 表现就是"拖了会弹回原位、缩放不生效"。
  Rect _resolveRect(ChatWindowState window, {required bool floating}) {
    final live = _liveRect;
    if (live != null) {
      return live;
    }

    // 窄屏：铺满整块区域。不销毁也不缩到角落——拉宽窗口后还要原样回来。
    if (!widget.wide) {
      return Offset.zero & widget.viewport;
    }

    if (floating) {
      final origin = window.origin;
      final size = window.size;
      if (origin != null && size != null) {
        return clampFloatRect(origin & size, widget.viewport);
      }
      return resolveFloatRect(
        viewport: widget.viewport,
        restored: window.restored,
      );
    }

    final columns = _columns;

    // 中栏宽度为 0（面板全屏）那一帧：先按浮窗落点渲染，避免用 0 宽去布局
    // 消息列表。正常情况下这时 `floating` 已经是 true，走不到这里。
    if (columns == null || columns.centerWidth <= 0) {
      return resolveFloatRect(
        viewport: widget.viewport,
        restored: window.restored,
      );
    }

    return Rect.fromLTWH(
      columns.centerLeft,
      0,
      columns.centerWidth,
      widget.viewport.height,
    );
  }

  /// 手势开始时用的"这一帧按哪种形态画"。
  bool get _rendersFloating {
    final window = ref.read(chatWindowProvider);
    return !widget.wide || window.floating || widget.fill;
  }

  /// 浮窗 / 停靠共用的外壳：圆角、投影、描边与拖拽热区。
  Widget _window(
    BuildContext context, {
    required ConversationTarget chat,
    required ChatPresentation presentation,
    required bool decorated,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final radius = decorated ? AppRadius.lg : 0.0;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      key: kChatWindowKey,
      child: AnimatedContainer(
        duration: _animating && !_dragging && !_resizing
            ? kChatFloatDuration
            : Duration.zero,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: decorated
              ? <BoxShadow>[
                  BoxShadow(
                    // 暗色主题下阴影几乎看不见，靠描边补层次；这里把 alpha
                    // 提一点，让浮窗在深色背景上仍然"浮"得起来。
                    color: Colors.black.withValues(alpha: dark ? 0.32 : 0.16),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        // 描边画在内容之上：画在下面会被 ClipRRect 裁掉一半，边缘只剩一条虚线。
        foregroundDecoration: decorated
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              )
            : null,
        // 圆角裁剪**只包正文**，热区层必须留在裁剪外面。
        //
        // `RenderClipRRect.hitTest` 会拒绝落在圆角外的点：四个角的 18dp 热区
        // 有一大半在弧线外侧，于是"左边、下边有光标，角上什么都没有"。
        // 桌面窗口的圆角处本来也能拉，这里与它保持一致。
        child: Stack(
          children: <Widget>[
            // 固定 index 0：它下面增删拖拽热区不会挤动这个 Element。
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                // 这里**不能**声明 `PageBackdropScope`：窄屏按整页画时必须自己
                // 铺一层不透明底色，否则下层的标签页（项目列表、底部导航）会
                // 从透明的 Scaffold 里透出来，看着像两个页面叠在一起。
                // 渐变起点比骨架低一个状态栏高度（约 3% 的渐变进度），肉眼看不出。
                child: _pane(chat, presentation),
              ),
            ),
            if (decorated) _dragArea(),
            if (decorated) _resizeRegions(),
          ],
        ),
      ),
    );
  }

  /// 会话视图本体。同一个 `conversationId` 永远用同一个 key：
  /// 停靠 ⇄ 浮窗切换时 State（消息、流、滚动、草稿）必须原样留着。
  Widget _pane(ConversationTarget chat, ChatPresentation presentation) {
    // 换会话 = 换一段对话：旧的锚点必须换掉，否则新的会话页会被"迁移"到
    // 上一段的 Element 上，显示的还是旧消息。
    if (_paneAnchorConversationId != chat.conversationId) {
      _paneAnchorConversationId = chat.conversationId;
      _paneAnchor = GlobalKey(debugLabel: 'chat-pane-${chat.conversationId}');
      _paneCache = null;
      _paneCacheKey = null;
    }

    // 形态与标题都会进 widget 的参数，变了就得重建 widget（State 仍保留）。
    final cacheKey = '${chat.conversationId}|${presentation.name}|${chat.title}';
    final cached = _paneCache;
    if (cached != null && _paneCacheKey == cacheKey) {
      return cached;
    }

    final floating = presentation == ChatPresentation.floating;
    final pane = ChatPage(
      key: _paneAnchor,
      conversationId: chat.conversationId,
      title: chat.title,
      projectPath: chat.projectPath,
      projectId: chat.projectId,
      presentation: presentation,
      onOpenTask: (taskId) => ref
          .read(shellTargetProvider.notifier)
          .select(
            TaskTarget(
              projectId: chat.projectId,
              taskId: taskId,
              title: '任务',
            ),
          ),
      onClose: _closeChat,
      // 窄屏铺满时是整页形态：返回箭头没有路由可退（这一层不在路由栈里），
      // 由外壳给它一个"收起这一屏、回到项目"的落点。
      onBack: presentation == ChatPresentation.page ? _closeChat : null,
      onRenamed: (title) {
        ref
            .read(shellTargetProvider.notifier)
            .retitle(chat.conversationId, title);
        ref.read(chatWindowProvider.notifier).retitle(chat.conversationId, title);
        _invalidateConversationViews(ref, chat.projectId);
      },
      onDeleted: () {
        _invalidateConversationViews(ref, chat.projectId);
        final targets = ref.read(shellTargetProvider.notifier);
        // 先收浮窗再导航：顺序反过来会留下一个指向已删会话的 pinned。
        ref.read(chatWindowProvider.notifier).close();
        targets.backToProject();
        targets.forgetConversation(chat.conversationId);
      },
      // 只有停靠态才提供「缩小」：浮窗已经是小窗，整页形态也不属于三栏骨架。
      onFloat: presentation == ChatPresentation.docked
          ? () => _floatChat(chat)
          : null,
      // 窄屏铺满时没有中栏可停靠；右侧栏全屏时同样没有——那时先把全屏退掉。
      onDock: floating && widget.wide && !widget.fill
          ? () {
              // 顺序不能反：`dock()` 之后中栏显示的是 `shellTarget`，
              // 而浮窗期间它已经被让给项目了。先停靠再选中会话，
              // 两步在同一个事件里完成，中间不会有一帧"没有窗口"。
              ref.read(chatWindowProvider.notifier).dock();
              ref.read(shellTargetProvider.notifier).select(chat);
            }
          : null,
      onCloseWindow: floating
          ? () {
              if (widget.fill) {
                // 全屏里这一枚只是"把刚叫出来的收回去"，不结束会话：
                // 会话本身还要留在中栏，退出全屏就能看到。
                ref.read(chatWindowProvider.notifier).setPeekInFullscreen(false);
              } else {
                ref.read(chatWindowProvider.notifier).close();
              }
            }
          : null,
    );

    _paneCache = pane;
    _paneCacheKey = cacheKey;
    return pane;
  }

  /// 缩小为浮窗：先把会话冻进浮窗，再把中栏让回它所属的项目。
  ///
  /// 两步必须在同一个事件里完成：中间不留一帧"浮窗已开、中栏还是这个会话"，
  /// 否则 `build` 里的自动停靠会立刻把它按回去。
  void _floatChat(ConversationTarget chat) {
    ref.read(chatWindowProvider.notifier).float(chat);
    ref.read(shellTargetProvider.notifier).backToProject();
  }

  /// 关闭会话：收浮窗（可能是空的）并回到项目。
  void _closeChat() {
    ref.read(chatWindowProvider.notifier).close();
    ref.read(shellTargetProvider.notifier).backToProject();
  }

  /// 浮窗栏头左侧的拖拽区。
  ///
  /// 宽度让出右侧 96：那里是「停靠 / … / 关闭」三枚按钮，被这层盖住就点不动了。
  /// 这里**不能**包 `WindowDragArea`——那是拖整个窗口的。
  Widget _dragArea() {
    return Positioned(
      key: kChatFloatHeaderDragKey,
      left: 0,
      top: 0,
      right: 96,
      height: kPaneHeaderHeight,
      child: MouseRegion(
        cursor: _dragging
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _handleDragStart,
          onPanUpdate: _handleDragUpdate,
          onPanEnd: (_) => _finishGesture(),
          onPanCancel: _finishGesture,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// 可以拉伸的边与角。
  ///
  /// 顶部不做：那一整条是窗口的拖拽栏头，把最上面 8dp 变成"缩放"会让人
  /// 抓不住窗口。右边也不做：会话正文的滚动条就贴着右边缘，抢了它等于
  /// 让用户没法拖滚动条——桌面窗口没有这个冲突，浮窗有。
  Widget _resizeRegions() {
    Widget handle(_ResizeEdge edge) {
      return MouseRegion(
        cursor: edge.cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _handleResizeStart(edge),
          onPanUpdate: _handleResizeUpdate,
          onPanEnd: (_) => _finishGesture(),
          onPanCancel: _finishGesture,
          child: const SizedBox.expand(),
        ),
      );
    }

    return Stack(
      children: <Widget>[
        // 下边缘：避开两个角，免得和角上的手势打架。
        Positioned(
          key: kChatFloatResizeBottomKey,
          left: _kResizeCorner,
          right: _kResizeCorner,
          bottom: 0,
          height: _kResizeEdge,
          child: handle(_ResizeEdge.bottom),
        ),
        // 左边缘：从栏头下沿开始，避开右上角的标题栏拖拽区。
        Positioned(
          key: kChatFloatResizeLeftKey,
          left: 0,
          top: kPaneHeaderHeight,
          bottom: _kResizeCorner,
          width: _kResizeEdge,
          child: handle(_ResizeEdge.left),
        ),
        Positioned(
          left: 0,
          bottom: 0,
          width: _kResizeCorner,
          height: _kResizeCorner,
          child: handle(_ResizeEdge.bottomLeft),
        ),
        // 右下角：测试里拖动的就是这一个。
        // 不画斜线提示：光标在悬停时已经换成左右箭头，再加一组贴边的短线
        // 反而像渲染瑕疵（圆角处尤其明显）。
        Positioned(
          key: kChatFloatResizeKey,
          right: 0,
          bottom: 0,
          width: _kResizeCorner,
          height: _kResizeCorner,
          child: handle(_ResizeEdge.bottomRight),
        ),
      ],
    );
  }

  void _handleDragStart(DragStartDetails details) {
    final base = _resolveRect(
      ref.read(chatWindowProvider),
      floating: _rendersFloating,
    );
    setState(() {
      _gestureBase = base;
      _dragOffset = Offset.zero;
      _liveRect = base;
      _dragging = true;
      _animating = false;
    });
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final base = _gestureBase;
    if (base == null) {
      return;
    }
    _dragOffset += details.delta;
    setState(() {
      _liveRect = clampFloatRect(base.shift(_dragOffset), widget.viewport);
    });
  }

  void _handleResizeStart(_ResizeEdge edge) {
    final base = _resolveRect(
      ref.read(chatWindowProvider),
      floating: _rendersFloating,
    );
    setState(() {
      _gestureBase = base;
      _dragOffset = Offset.zero;
      _liveRect = base;
      _resizeEdge = edge;
      _resizing = true;
      _animating = false;
    });
  }

  void _handleResizeUpdate(DragUpdateDetails details) {
    final base = _gestureBase;
    if (base == null) {
      return;
    }
    _dragOffset += details.delta;

    // 每条边只动自己那一侧：拖左边时右边界必须钉住，否则窗口会"边缩边跑"。
    final edge = _resizeEdge;
    var left = base.left;
    var top = base.top;
    var right = base.right;
    var bottom = base.bottom;

    if (edge.movesLeft) {
      left += _dragOffset.dx;
    }
    if (edge.movesRight) {
      right += _dragOffset.dx;
    }
    if (edge.movesBottom) {
      bottom += _dragOffset.dy;
    }
    if (edge.movesTop) {
      top += _dragOffset.dy;
    }

    // 最小尺寸先兜一层：`clampFloatRect` 只保证"不小于最小值、不越界"，
    // 但它不认方向——先在这里把被拖的那条边停在最小尺寸上，手感才是"顶住"，
    // 而不是"整体被推着走"。
    if (right - left < kChatFloatMinWidth) {
      if (edge.movesLeft) {
        left = right - kChatFloatMinWidth;
      } else {
        right = left + kChatFloatMinWidth;
      }
    }
    if (bottom - top < kChatFloatMinHeight) {
      bottom = top + kChatFloatMinHeight;
    }

    setState(() {
      _liveRect = clampFloatRect(
        Rect.fromLTRB(left, top, right, bottom),
        widget.viewport,
      );
    });
  }

  /// 手势收尾：把最终矩形交回状态层（那里做最后一次 clamp 并异步落盘）。
  void _finishGesture() {
    final rect = _liveRect;
    setState(() {
      _dragging = false;
      _resizing = false;
      _liveRect = null;
      _gestureBase = null;
      _dragOffset = Offset.zero;
    });
    if (rect != null) {
      ref.read(chatWindowProvider.notifier).place(rect, widget.viewport);
    }
  }

  void _handleAnimationEnd() {
    if (!_animating || !mounted) {
      return;
    }
    setState(() => _animating = false);
  }
}

/// 会话被改名 / 删除后要一起刷新的两个视图：侧栏与项目页共用的会话列表，
/// 以及项目本身（它的会话计数跟着变）。
///
/// 无归属直聊（`projectId` 为空）不进任何项目视图，只刷侧栏「对话」分组。
void _invalidateConversationViews(WidgetRef ref, String projectId) {
  if (projectId.isEmpty) {
    ref.invalidate(unassignedConversationsProvider);
    return;
  }
  ref.invalidate(conversationsProvider(projectId));
  ref.invalidate(projectProvider(projectId));
}

/// 浮窗可以拉伸的方向。
///
/// 只有左、下两组：顶部那条是窗口的拖拽栏头，右边缘压着会话的滚动条。
/// 这是"浮窗"与"父窗"的差别——主窗口四边都能拉，是因为它边缘没有这两种东西。
enum _ResizeEdge {
  left,
  bottom,
  bottomLeft,
  bottomRight;

  bool get movesLeft => this == left || this == bottomLeft;

  bool get movesRight => this == bottomRight;

  /// 顶部不参与：栏头要留给"拖动窗口"。
  bool get movesTop => false;

  bool get movesBottom => this != left;

  /// 悬停与拖动期间的光标。
  ///
  /// 角上刻意不用 `resizeDownRight` / `resizeDownLeft`：macOS 引擎的
  /// `FlutterMouseCursorPlugin` 只映射了 resizeColumn / row / up / down /
  /// left / right / upDown / leftRight 这几项，斜向那几枚不在表里，
  /// `GetCursorForKind` 会退回 `arrowCursor`——表现就是"悬停完全没反应"。
  /// 退到左右箭头：它至少明确表达"这里能拉着改宽度"，横向拖动也是角上最常用的。
  MouseCursor get cursor => switch (this) {
    _ResizeEdge.left => SystemMouseCursors.resizeLeftRight,
    _ResizeEdge.bottom => SystemMouseCursors.resizeUpDown,
    _ResizeEdge.bottomLeft => SystemMouseCursors.resizeLeftRight,
    _ResizeEdge.bottomRight => SystemMouseCursors.resizeLeftRight,
  };
}

/// 浮窗右下角**不再画**任何手柄装饰：缩放在悬停时由光标表达，
/// 贴边的小短线在圆角处会被看成渲染瑕疵。


