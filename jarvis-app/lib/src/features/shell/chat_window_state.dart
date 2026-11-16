import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../core/window_chrome.dart';
import 'shell_layout_state.dart';

/// 浮窗默认尺寸。
///
/// 420×560 是「一屏能读两三条回答、输入栏不被压扁」的最小体量：再窄，代码块与
/// 表格会挤成横向滚动条；再宽，浮窗就失去"小窗"的意义，不如直接停靠。
const double kChatFloatWidth = 420;
const double kChatFloatHeight = 560;

/// 浮窗最小尺寸。
///
/// 340 还能放下输入栏的权限胶囊与发送按钮，320 高刚好是"栏头 + 两行气泡 +
/// 输入栏"。再小就只能看见一段残影，拖动与缩放的收益还不如直接停靠。
const double kChatFloatMinWidth = 340;
const double kChatFloatMinHeight = 320;

/// 默认落点距窗口右、下边缘的距离。
const double kChatFloatMargin = 24;

/// 收缩 / 停靠的过渡时长。
///
/// 与骨架的模式渐变（250ms）同一量级：再快看不出"同一个窗口在移动"，
/// 再慢会挡住用户马上要做的事。
const Duration kChatFloatDuration = Duration(milliseconds: 220);

/// 浮窗几何的存储键。与 `ui_theme_mode` / `ui_project_mode` 同一命名空间：
/// 属于界面偏好，丢了只影响观感，不影响配对与鉴权。
const String kChatFloatGeometryKey = 'ui_chat_float_geometry';

/// 中栏栏头「缩小为浮窗」按钮。
const Key kChatFloatKey = Key('shell-chat-float');

/// 浮窗栏头「停靠回中栏」按钮。
const Key kChatDockKey = Key('shell-chat-dock');

/// 浮窗栏头「关闭小窗」按钮。
///
/// 与栏头菜单里的「关闭会话」不是一回事：这一枚只收浮窗，不动中栏当前页。
const Key kChatFloatCloseKey = Key('shell-chat-float-close');

/// 浮窗栏头的拖拽区（标题那段）。拖动是纯手势，测试只能靠 Key 定位。
const Key kChatFloatHeaderDragKey = Key('shell-chat-float-drag');

/// 浮窗右下角的缩放热区。
const Key kChatFloatResizeKey = Key('shell-chat-float-resize');

/// 右侧栏全屏时，工具条里的「聊天浮窗」开关。
///
/// 全屏的语义是"这一栏独占整窗"，聊天窗口默认让位；要边看文件边聊，
/// 就用这一枚把它叫出来。它与中栏栏头那枚「缩小为浮窗」不是一回事：
/// 后者改的是形态，前者只改"全屏时露不露面"。
const Key kChatFloatPeekKey = Key('shell-chat-float-peek');

/// 下边缘 / 左边缘的缩放热区。
///
/// 单独给 Key 是为了让测试能断言"悬停在可拉伸的地方会换光标"——
/// 光标只体现在 `MouseRegion.cursor` 上，没有文案也没有图标可定位。
const Key kChatFloatResizeBottomKey = Key('shell-chat-float-resize-bottom');
const Key kChatFloatResizeLeftKey = Key('shell-chat-float-resize-left');

/// 聊天窗口本体的 Key。
///
/// 它与会话 id 无关：测试要断言"停靠与浮窗是同一个窗口、State 没重建"，
/// 窗口的 key 一旦跟着形态或会话变，这条断言就失去意义。
const Key kChatWindowKey = Key('shell-chat-window');

/// 浮窗几何的三元组：位置、尺寸，以及**落盘那一刻的视口尺寸**。
///
/// 存视口尺寸是为了区分"用户只是重启了"与"用户换了块屏幕"：前者要严格还原
/// 绝对坐标，后者必须按比例迁移，否则 4K 上的右下角浮窗在笔记本上会整块跑到
/// 视口外，被 clamp 到左上角——用户会认为"根本没记住"。
@immutable
class ChatFloatGeometry {
  const ChatFloatGeometry({
    required this.origin,
    required this.size,
    required this.viewport,
  });

  final Offset origin;
  final Size size;
  final Size viewport;

  @override
  bool operator ==(Object other) =>
      other is ChatFloatGeometry &&
      other.origin == origin &&
      other.size == size &&
      other.viewport == viewport;

  @override
  int get hashCode => Object.hash(origin, size, viewport);
}

/// 落盘用的 JSON。字段名保持短名，值全是数字，便于跨版本兼容。
String encodeChatFloatGeometry(ChatFloatGeometry geometry) =>
    jsonEncode(<String, double>{
      'x': geometry.origin.dx,
      'y': geometry.origin.dy,
      'w': geometry.size.width,
      'h': geometry.size.height,
      'vw': geometry.viewport.width,
      'vh': geometry.viewport.height,
    });

/// 严格解析：只认"六个有限正数"这一种形状。
///
/// 脏值（null、空串、缺字段、NaN、负尺寸、老版本写坏的内容）一律返回 null
/// 交给调用方回落默认落点——静默猜一个相近值会让用户觉得"位置自己跑了"。
ChatFloatGeometry? decodeChatFloatGeometry(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    double? number(String key) {
      final value = decoded[key];
      return value is num && value.isFinite ? value.toDouble() : null;
    }

    final x = number('x');
    final y = number('y');
    final w = number('w');
    final h = number('h');
    final vw = number('vw');
    final vh = number('vh');
    if (x == null ||
        y == null ||
        w == null ||
        h == null ||
        vw == null ||
        vh == null ||
        w <= 0 ||
        h <= 0 ||
        vw <= 0 ||
        vh <= 0) {
      return null;
    }
    return ChatFloatGeometry(
      origin: Offset(x, y),
      size: Size(w, h),
      viewport: Size(vw, vh),
    );
  } on FormatException {
    return null;
  }
}

/// 默认落点：右下角，距右、距下各 [kChatFloatMargin]。
Rect defaultFloatRect(Size viewport) {
  final vw = math.max(1.0, viewport.width);
  final vh = math.max(1.0, viewport.height);
  final w = math.min(kChatFloatWidth, math.max(0.0, vw - 2 * kChatFloatMargin));
  final h = math.min(kChatFloatHeight, math.max(0.0, vh - 2 * kChatFloatMargin));
  return clampFloatRect(
    Rect.fromLTWH(vw - w - kChatFloatMargin, vh - h - kChatFloatMargin, w, h),
    viewport,
  );
}

/// 把上次落盘的几何还原成当前视口里的矩形。
///
/// 两种情况刻意分开：
/// - 视口尺寸变化在 ±200dp 内：认为是"同一次使用"（重启、轻微改窗口），
///   严格还原绝对位置，用户拖到哪儿就是哪儿；
/// - 变化更大（换显示器、最大化）：按比例迁移，保证浮窗还在视野里。
///
/// 尺寸本身**不按比例放大**：420 宽的聊天窗口在 4K 屏上仍然是 420——
/// 它是一块对话面板，不是"按窗口比例缩放的面板"。
Rect resolveFloatRect({
  required Size viewport,
  ChatFloatGeometry? restored,
}) {
  if (restored == null) {
    return defaultFloatRect(viewport);
  }

  final vw = math.max(1.0, viewport.width);
  final vh = math.max(1.0, viewport.height);
  final sameShape =
      (vw - restored.viewport.width).abs() < 200 &&
      (vh - restored.viewport.height).abs() < 200;
  final scaleX = sameShape ? 1.0 : vw / restored.viewport.width;
  final scaleY = sameShape ? 1.0 : vh / restored.viewport.height;

  return clampFloatRect(
    Rect.fromLTWH(
      restored.origin.dx * scaleX,
      restored.origin.dy * scaleY,
      restored.size.width,
      restored.size.height,
    ),
    viewport,
  );
}

/// 唯一的位置约束入口：默认落点、恢复、拖动、缩放全部要过这一道。
///
/// 三条边界：
/// - 左右不越出视口；
/// - 顶部不高于中栏栏头下沿（`kPaneHeaderHeight`）：浮窗压到窗口最顶端会盖住
///   栏头按钮，macOS 上还会和红绿灯打架，同时骨架那条横线会从浮窗中间穿过去；
/// - macOS 隐藏标题栏时，左上 78×32 是原生绘制的红绿灯，浮窗不能落在那块上。
Rect clampFloatRect(Rect rect, Size viewport) {
  final vw = math.max(1.0, viewport.width);
  final vh = math.max(1.0, viewport.height);

  // 视口比最小尺寸还小时，上界就是视口本身：clamp 的下界不能大于上界。
  final w = rect.width.clamp(math.min(kChatFloatMinWidth, vw), vw).toDouble();
  final h = rect.height.clamp(math.min(kChatFloatMinHeight, vh), vh).toDouble();

  // 顶部下限是栏头下沿；但窗口比"栏头 + 浮窗"还矮时，只能优先保证整个窗口
  // 落在视口里——那时 topMin 会退到 0（浮窗会盖住栏头，好过一半在窗口外）。
  final topMin = math.min(kPaneHeaderHeight, math.max(0.0, vh - h));
  final topMax = math.max(topMin, vh - h);
  var top = rect.top.clamp(topMin, topMax).toDouble();
  var left = rect.left.clamp(0.0, math.max(0.0, vw - w)).toDouble();

  if (usesHiddenWindowTitleBar && top < kMacWindowButtonsHeight) {
    final macLeftMin = math.min(kMacWindowButtonsWidth, math.max(0.0, vw - w));
    left = left.clamp(macLeftMin, math.max(macLeftMin, vw - w)).toDouble();
  }

  return Rect.fromLTWH(left, top, w, h);
}

/// 聊天窗口的形态与浮窗几何。
///
/// 只有一份状态：同一时刻只有一个聊天窗口（见 `ChatWindowLayer` 的解析）。
/// 三种形态里 `page`（窄屏整页路由）不经过这里，它由 `conversations_page` 直接 push。
@immutable
class ChatWindowState {
  const ChatWindowState({
    this.floating = false,
    this.pinned,
    this.origin,
    this.size,
    this.restored,
    this.peekInFullscreen = false,
  });

  /// 是否处于浮窗形态。停靠态为 false。
  final bool floating;

  /// 浮窗期间冻结的会话。
  ///
  /// 之所以不直接把 `shellTarget` 当唯一来源：浮窗打开后中栏会被让给项目 /
  /// 任务 / 空态，那时 `shellTarget` 已经不是会话了，但浮窗里显示的那一段不能跟着跑。
  final ConversationTarget? pinned;

  /// 本次使用期间拖出来的左上角。null 表示"还没拖过"，按 [restored] 或默认落点算。
  final Offset? origin;

  /// 本次使用期间缩放出来的尺寸。null 同上。
  final Size? size;

  /// 上次启动落盘的几何。恢复完成前为 null。
  final ChatFloatGeometry? restored;

  /// 右侧栏全屏期间，用户是否主动把聊天窗口叫了出来。
  ///
  /// 与 [floating] 分开：它不改形态，只决定"全屏时露不露面"。退出全屏或
  /// 换会话时都会清掉，免得下次进全屏又自己冒出来。
  final bool peekInFullscreen;

  /// 有没有可用的浮窗几何（拖过或恢复过）。
  bool get hasGeometry => origin != null && size != null;

  ChatWindowState copyWith({
    bool? floating,
    ConversationTarget? pinned,
    bool clearPinned = false,
    Offset? origin,
    Size? size,
    ChatFloatGeometry? restored,
    bool? peekInFullscreen,
  }) {
    return ChatWindowState(
      floating: floating ?? this.floating,
      pinned: clearPinned ? null : (pinned ?? this.pinned),
      origin: origin ?? this.origin,
      size: size ?? this.size,
      restored: restored ?? this.restored,
      peekInFullscreen: peekInFullscreen ?? this.peekInFullscreen,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatWindowState &&
      other.floating == floating &&
      other.pinned == pinned &&
      other.origin == origin &&
      other.size == size &&
      other.restored == restored &&
      other.peekInFullscreen == peekInFullscreen;

  @override
  int get hashCode =>
      Object.hash(floating, pinned, origin, size, restored, peekInFullscreen);
}

/// 聊天窗口的形态与浮窗几何。
final NotifierProvider<ChatWindowController, ChatWindowState>
chatWindowProvider = NotifierProvider<ChatWindowController, ChatWindowState>(
  ChatWindowController.new,
);

class ChatWindowController extends Notifier<ChatWindowState> {
  @override
  ChatWindowState build() {
    // 与主题偏好同一套：不阻塞首帧，读不到就按默认右下角。
    unawaited(restore());
    return const ChatWindowState();
  }

  /// 从本地存储恢复上次的浮窗几何。
  ///
  /// 公开而不是藏在 build 里：测试要能确定性地"等恢复完成再断言"，
  /// 生产路径仍然是 build 里 `unawaited` 一次。
  Future<void> restore() async {
    try {
      final raw = await ref.read(secretStoreProvider).read(kChatFloatGeometryKey);
      final geometry = decodeChatFloatGeometry(raw);
      if (geometry == null || geometry == state.restored) {
        return;
      }
      state = state.copyWith(restored: geometry);
    } on Exception {
      // 钥匙串/回退目录在测试与 headless 环境里都可能不可用：
      // 读不出来就用默认落点，不能让它冒成未捕获异常，更不该卡住启动。
    }
  }

  /// 落盘浮窗几何。
  ///
  /// 只在手势结束时调用：拖动过程中每帧写一次会把手势变成 IO 风暴，
  /// 而失败也只影响"下次启动记不记住"，当前这次用户已经看到了。
  Future<void> persist(ChatFloatGeometry geometry) async {
    try {
      await ref
          .read(secretStoreProvider)
          .write(kChatFloatGeometryKey, encodeChatFloatGeometry(geometry));
    } on Exception {
      // 同上：偏好落盘失败不该冒泡到 UI。
    }
  }

  /// 缩小为浮窗。会话对象一起冻进来，之后中栏怎么切都不影响这一份。
  void float(ConversationTarget chat) {
    state = state.copyWith(
      floating: true,
      pinned: chat,
      // 换形态就不该继承"全屏时露过面"的临时状态。
      peekInFullscreen: false,
    );
  }

  /// 停靠回中栏：浮窗标记与冻结的会话一起交还给 `shellTarget`。
  void dock() {
    state = state.copyWith(
      floating: false,
      clearPinned: true,
      peekInFullscreen: false,
    );
  }

  /// 关闭浮窗，但不导航。
  ///
  /// 与栏头菜单的「关闭会话」区分：那一项要回到项目、并刷新列表；
  /// 浮窗右上角这一枚只让窗口消失，中栏原本显示什么继续显示什么。
  void close() {
    state = state.copyWith(
      floating: false,
      clearPinned: true,
      peekInFullscreen: false,
    );
  }

  /// 右侧栏全屏时，把聊天窗口叫出来 / 收回去。
  void setPeekInFullscreen(bool peek) {
    if (state.peekInFullscreen == peek) {
      return;
    }
    state = state.copyWith(peekInFullscreen: peek);
  }

  /// 退出全屏时归位：全屏里露过面，不代表下一次进全屏还要自己冒出来。
  void clearPeek() {
    if (!state.peekInFullscreen) {
      return;
    }
    state = state.copyWith(peekInFullscreen: false);
  }

  /// 手势结束后的落点：更新矩形并按视口落盘。
  void place(Rect rect, Size viewport) {
    final clamped = clampFloatRect(rect, viewport);
    state = state.copyWith(origin: clamped.topLeft, size: clamped.size);
    unawaited(
      persist(
        ChatFloatGeometry(
          origin: clamped.topLeft,
          size: clamped.size,
          viewport: viewport,
        ),
      ),
    );
  }

  /// 会话改名后同步浮窗里那一份：否则浮窗栏头与关闭落点还是旧标题。
  void retitle(String conversationId, String title) {
    final chat = state.pinned;
    if (chat == null ||
        chat.conversationId != conversationId ||
        chat.title == title) {
      return;
    }
    state = state.copyWith(
      pinned: ConversationTarget(
        projectId: chat.projectId,
        conversationId: chat.conversationId,
        title: title,
        projectPath: chat.projectPath,
        project: chat.project,
      ),
    );
  }
}
