import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/recording/recording_models.dart';

/// 宽屏侧栏默认宽度。
///
/// 240 只够放下一行标题，导航树里的「会话标题 + 相对时间」会被挤成一串省略号；
/// 280 是这两类信息都能读全的最小值，同时保证断点 700 上右侧仍有 420。
const double kShellRailWidth = 280;

/// 宽度断点：窄于此值保持顶部单列布局，宽于此值把顶栏与模式下拉挪到左侧侧栏。
///
/// 700 而不是"手机宽度"：这个值同时区分了手机（单列）与桌面窗口（≥900 设计宽度），
/// 平板横屏落在宽屏一侧，正好能用上左侧侧栏与导航树。
/// 窄屏的项目列表仍是 `ProjectsPage`，列数判定用它自身的宽度（同一个数值）。
///
/// 会话页也用它判断"有没有右栏"：工具要求打开页面时，宽屏开右栏标签、
/// 窄屏交给系统浏览器。
const double kShellBreakpoint = 700;

/// 拖动下限：再窄就放不下项目名、计数徽标与展开箭头。
///
/// 拖到这个值以下不会"卡住"，但也不会立刻收起：宽度先冻结在最后一个合法值，
/// 需要继续朝同一方向按住拖满 `kCollapseHoldDuration` 才真的收起
/// （见 `shell_resize_handle.dart`）。桌面工具里把栏拉窄到底本来就等于关掉它，
/// 只是"一下就关"太容易误触，所以中间加了一道蓄力。
///
/// 收起后手势不中断：反向回拉 `kSashReopenPull` 就能把栏按原宽度拉回来。
const double kRailMinWidth = 260;

/// 拖动上限：再宽，1280 窗口里的会话正文就只剩一条窄缝。
const double kRailMaxWidth = 420;

/// 右侧内容区的最小宽度。
///
/// 拖动分隔条时先压侧栏：宁可侧栏停在 [kRailMinWidth]，也不让详情区被挤到不可读。
const double kPaneMinWidth = 380;

/// 分隔条命中区宽度。视觉上仍是 1px 细线，只是可点/可拖的范围更宽。
const double kRailHandleWidth = 8;

/// 三栏内容区统一的水平内边距：内容边缘到栏边界（或分隔线）的视觉距离。
///
/// 左栏、中栏、右栏的内容都按这个值贴边，三栏的左右呼吸才一致。
const double kPaneContentInset = 12;

/// 贴着分隔线那一侧的内边距。
///
/// 拖动条那 8dp 命中区被涂成相邻栏的底色（见 `ShellResizeHandle.fillColor`），
/// 视觉上属于那一栏而不是缝隙，所以这一侧要扣掉它，
/// 内容到分隔线的实际距离才等于 [kPaneContentInset]。
const double kPaneEdgeInset = kPaneContentInset - kRailHandleWidth;

/// 侧栏行「悬停 / 选中」圆角块相对栏边缘的留白。
///
/// 左右两栏镜像使用：
/// - 左栏：左侧是窗口边缘，留 8；右侧贴着分隔线，那 8dp 是拖动条的命中区、
///   涂成栏底色（见 `ShellResizeHandle.fillColor`），视觉上属于栏内，
///   所以块贴住栏右缘时到分隔线同样是 8——右侧实写 [kRailHandleWidth] 的差值。
/// - 右栏：反过来，左侧贴分隔线、右侧是窗口边缘留 8。注意右栏的拖动条在
///   **聊天浮窗让位 / 面板全屏**时会被拿掉（`showHandle = false`），那时面板
///   左缘就是分隔线，行块必须自己让出这 8；有拖动条时才靠它让。
///
/// 放在布局常量里而不是左栏组件里：文件树也要用同一个间距，两处各写一个 8
/// 迟早会把两栏的行底色对不齐。
const double kRailRowPillInset = 8;

/// 右栏标签本体（圆角块）的高度。
///
/// 提成常量是为了让 [kPaneHeaderHeight] 能由它推导：标签高度一变，
/// 首行高度跟着变，"标签上下留白"就不会被吃掉。
const double kPanelTabHeight = 26;

/// 标签在首行里的上下留白（参考 Codex：标签四周约 6–7dp）。
///
/// 这是"标签上下间距"的唯一取值处：首行高度必须容纳它，
/// 标签才不会被压到栏顶，也不会贴住栏底的分隔线。
const double kPaneHeaderVerticalPadding = 7;

/// 首行底部那条分隔线的粗细。
///
/// 它画在首行的 [kPaneHeaderHeight] 之内（`Container` 的边框在 padding 外侧），
/// 所以标签下方真正留给留白的是 `kPaneHeaderVerticalPadding - 这个值`：
/// 上留白 7、下留白 6 + 线 1，标签到首行上下外沿都是 7。
const double kPaneHeaderBorderWidth = 1;

/// 三栏首行（左栏红绿灯行 / 中栏工具栏 / 右栏标签栏）的高度。
///
/// 40 = 标签 26 + 上下各 7，而不是 Material 默认的 AppBar（56），也不是
/// 只够把按钮塞进去的 32：首行要和 macOS 红绿灯、桌面紧凑工具栏对齐，
/// 同时得给右栏标签留出与 Codex 同量级的呼吸空间。再高会把左栏的
/// 模式胶囊与导航树整体往下推。
const double kPaneHeaderHeight =
    kPanelTabHeight + 2 * kPaneHeaderVerticalPadding;

/// 栏头里图标按钮的命中区边长。
///
/// `IconButton` 默认 48 会把 [kPaneHeaderHeight] 撑高，统一收紧到 24。
/// 必须不大于 [kPanelTabHeight]：标签栏里按钮与标签同处一行，
/// 按钮一旦高过标签，加了上下留白的那条 Row 就会被撑破。
const double kPaneHeaderButtonSize = 24;

/// 栏头图标本身的尺寸。
///
/// 与 macOS 红绿灯的直径（12）一致：图标再大一圈时，即使中心对齐，
/// 视觉上也会显得按钮压过红绿灯、重心偏上/偏下。
const double kPaneHeaderIconSize = 14;

/// 左栏「行内图标」的统一尺寸（导航树行、搜索、设置齿轮）。
///
/// 比 [kPaneHeaderIconSize] 大 2：栏头那一族要和 24dp 命中区、右栏 26dp
/// 标签共存，图标不能太满；行内图标旁边是 13–14sp 正文，16 才是同一视觉重量。
const double kRailItemIconSize = 16;

/// 左栏开合按钮的 Key。
///
/// 宽屏下同一时刻只渲染一个：左栏展开时在左栏栏头，收起后移到中栏栏头。
const Key kRailToggleKey = Key('shell-rail-toggle');

/// 中栏空态（「聊天」开场页）的 Key。
///
/// 空态不再有一句可定位的引导文案，测试靠它断言"中栏现在是空态"，
/// 而不是依赖某段可能被改写的文字。
const Key kShellEmptyChatKey = Key('shell-empty-chat');

/// 中栏栏头「新建会话」的 Key。
///
/// 它只在左栏收起时渲染（展开时入口在左栏里），测试靠它断言这条显隐关系。
const Key kNewConversationKey = Key('shell-new-conversation');

/// 后退 / 前进按钮的 Key。
///
/// 与 [kRailToggleKey] 同一套互斥规则：左栏展开时在左栏栏头，收起后跟着
/// 开合按钮一起移到中栏栏头，同一时刻只有一份。
const Key kRailBackKey = Key('shell-rail-back');
const Key kRailForwardKey = Key('shell-rail-forward');

/// 分隔条的 Key。拖动是纯手势交互，没有文案可供测试定位，只能靠 Key。
const Key kRailResizeHandleKey = Key('shell-rail-resize-handle');

/// 窄屏顶栏「面板」入口的 Key。
///
/// 它与中栏的 [kFilePaneToggleKey] 是两套入口（整页 vs 浮层），
/// 测试要靠 Key 区分窄屏与宽屏各自该出现哪一个。
const Key kPanelEntryKey = Key('shell-panel-entry');

// 窄屏的「无限画布」入口在「我的」页：它和「记忆」一起放在那里，不再挂在
// 设置页的二级列表里（窄屏没有左栏，`kRailCanvasKey` 那一行不会渲染；
// 底部导航也没有画布这一档）。

/// 左栏顶部三行动作的 Key。
///
/// 「新建会话」「录音笔记」「无限画布」共用同一套行样式，测试靠 Key 而不是
/// 文案定位，文案以后要缩成「新建」也不会牵动断言。
const Key kRailNewConversationKey = Key('shell-rail-new-conversation');
const Key kRailRecordingsKey = Key('shell-rail-recordings');
const Key kRailCanvasKey = Key('shell-rail-canvas');

/// 左栏底部账户菜单的 Key：触发器一枚，菜单项各一枚。
///
/// 退出登录当前只是占位，测试仍需要一个稳定入口去点它。
const Key kRailAccountMenuKey = Key('shell-rail-account-menu');
const Key kRailAccountSettingsKey = Key('shell-rail-account-settings');
const Key kRailAccountMemoryKey = Key('shell-rail-account-memory');
const Key kRailAccountSignOutKey = Key('shell-rail-account-sign-out');

/// 宽屏左栏搜索入口的 Key（当前只是占位）。
///
/// 它只出现在「项目」标题行右端的第一枚图标；窄屏顶栏没有这一枚，
/// 测试用它断言"宽屏有、窄屏没有"。
const Key kRailSearchKey = Key('shell-rail-search');

/// 把用户拖出来的宽度收敛到当前窗口真正允许的区间。
///
/// `available` 是整个骨架的可用宽度（不含系统安全区），不是侧栏宽度；
/// 窗口刚过断点时右侧只剩 300 出头，此时上限会被压到 [kRailMinWidth]，
/// 于是侧栏"拖不动"——这比让右侧内容溢出更可接受。
double clampRailWidth({required double width, required double available}) {
  final upper = (available - kPaneMinWidth)
      .clamp(kRailMinWidth, kRailMaxWidth)
      .toDouble();
  return width.clamp(kRailMinWidth, upper);
}

/// 宽屏侧栏宽度。只在内存里活着：重启回到默认值，
/// 目前没有"记住窗口布局"的需求，写进设置只会多一份要迁移的存储。
final NotifierProvider<RailWidthController, double> railWidthProvider =
    NotifierProvider<RailWidthController, double>(RailWidthController.new);

class RailWidthController extends Notifier<double> {
  @override
  double build() => kShellRailWidth;

  /// 收下拖动产生的绝对宽度（调用方已经 clamp 过）。
  void resize(double width) => state = width;
}

/// 侧栏是否收起。与宽度分开存：收起再展开要回到用户拖出来的那个宽度，
/// 而不是回到默认的 280。
final NotifierProvider<RailCollapsedController, bool> railCollapsedProvider =
    NotifierProvider<RailCollapsedController, bool>(
      RailCollapsedController.new,
    );

class RailCollapsedController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  /// 收起。拖动分隔条蓄力满时由栏自己调用，
  /// 与栏头按钮的 `toggle` 分开：那条路径是"再点一下就展开"，不能混用。
  void collapse() => state = true;

  /// 展开。拖动条在收起态被反向拖回时由栏自己调用：这是"撤销刚才那一下"，
  /// 宽度原样还回去，不走 `toggle`（后者语义是"切换"，与手势无关）。
  void expand() => state = false;
}

/// 宽屏右侧当前呈现的对象。互斥，`null` 表示什么都没选（空状态）。
///
/// 侧栏高亮与右侧渲染都只读这一个状态，避免"侧栏选中的是 A、右侧还在显示 B"。
sealed class ShellTarget {
  const ShellTarget();

  /// 所属项目：侧栏用它决定展开哪一组、哪一行该高亮。
  ///
  /// 录音、记忆这类"工具页"没有项目归属，返回空串：
  /// 右栏据此退回"先在左侧选择一个项目"，与真正没选中时同一条兜底。
  String get projectId => '';
}

/// 选中项目：右侧显示它的「会话 / 任务」详情。
final class ProjectTarget extends ShellTarget {
  const ProjectTarget(this.project);

  final Project project;

  @override
  String get projectId => project.id;

  @override
  bool operator ==(Object other) =>
      other is ProjectTarget && other.project.id == project.id;

  @override
  int get hashCode => project.id.hashCode;
}

/// 选中会话：右侧直接显示对话。
final class ConversationTarget extends ShellTarget {
  const ConversationTarget({
    required this.projectId,
    required this.conversationId,
    required this.title,
    this.projectPath,
    this.project,
  });

  @override
  final String projectId;
  final String conversationId;

  /// 侧栏与右侧标题都用它；服务端异步生成标题后右侧会自行刷新。
  final String title;

  /// 所属项目目录，只用于编码任务对话框里"改的是哪儿"的只读展示。
  final String? projectPath;

  /// 所属项目。会话页的「关闭 / 删除」要回到它那一页，而只有 id 拼不出页面。
  /// 历史数据或外部直达可能没有，此时退回空状态。
  final Project? project;

  /// 相等性把 [title] 也算进去：改完标题换一个新实例，右侧与侧栏才拿得到新值。
  /// `conversationId` 仍是主体——同一个会话换标题还是"同一个会话"。
  @override
  bool operator ==(Object other) =>
      other is ConversationTarget &&
      other.conversationId == conversationId &&
      other.title == title;

  @override
  int get hashCode => Object.hash(conversationId, title);
}

/// 选中任务：右侧显示任务详情（计划 / 审批 / 产物）。
final class TaskTarget extends ShellTarget {
  const TaskTarget({
    required this.projectId,
    required this.taskId,
    required this.title,
  });

  @override
  final String projectId;
  final String taskId;

  /// 任务没有独立标题字段，口径与任务详情页一致：`skill ?? type`。
  final String title;

  @override
  bool operator ==(Object other) =>
      other is TaskTarget && other.taskId == taskId;

  @override
  int get hashCode => taskId.hashCode;
}

/// 录音笔记列表。左栏顶部那行入口点开后中栏原地显示它。
///
/// 录音三页（列表 / 详情 / 进行页）都是独立 target 而不是嵌套路由：
/// 它们要共用一个后退栈，才能和项目 / 会话页的栏头箭头同语义。
final class RecordingsTarget extends ShellTarget {
  const RecordingsTarget();

  @override
  bool operator ==(Object other) => other is RecordingsTarget;

  @override
  int get hashCode => (RecordingsTarget).hashCode;
}

/// 无限画布 Demo。左栏顶部第三行入口点开后中栏原地显示它。
///
/// 与录音 / 记忆同属"工具页"：[projectId] 为空串，右栏因此保留上一个
/// 项目不动——画布现在还不按项目归属，切进来不该把右栏的文件树清空。
final class CanvasTarget extends ShellTarget {
  const CanvasTarget();

  @override
  bool operator ==(Object other) => other is CanvasTarget;

  @override
  int get hashCode => (CanvasTarget).hashCode;
}

/// 一条录音的详情。`local` 与 `server` 至少给一个（口径同 [RecordingDetailPage]）。
///
/// 相等性只认 [key]：列表每次轮询都会给出新实例，按对象身份比会无谓地重建整页
/// （播放器位置、Tab、转写滚动位置一起丢）。
final class RecordingDetailTarget extends ShellTarget {
  const RecordingDetailTarget({this.local, this.server});

  final LocalRecording? local;
  final ServerRecording? server;

  /// 稳定键：本地账本优先，因为它是客户端自己生成的、上传前后不变。
  String get key => local?.clientId ?? server?.id ?? '';

  @override
  bool operator ==(Object other) =>
      other is RecordingDetailTarget && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// 正在录音的那一页。录音本身在全局控制器里，这一页只是它的视图。
final class RecordingSessionTarget extends ShellTarget {
  const RecordingSessionTarget();

  @override
  bool operator ==(Object other) => other is RecordingSessionTarget;

  @override
  int get hashCode => (RecordingSessionTarget).hashCode;
}

/// 记忆列表页。
final class MemoryTarget extends ShellTarget {
  const MemoryTarget();

  @override
  bool operator ==(Object other) => other is MemoryTarget;

  @override
  int get hashCode => (MemoryTarget).hashCode;
}

/// 这一页是不是录音家族（列表 / 详情 / 进行页）。
///
/// 左栏那行「录音笔记」在这三种状态下都要保持选中态：用户点开的是同一个入口，
/// 只是里面又往里走了一层。
bool isRecordingPageTarget(ShellTarget? target) =>
    target is RecordingsTarget ||
    target is RecordingDetailTarget ||
    target is RecordingSessionTarget;

/// 中栏能不能后退 / 前进。
///
/// 只装两个布尔值，不携带栈本身：按钮只需要知道亮不亮，栈仍由
/// [ShellTargetController] 独占。按值实现 `==`，栈没变化时 Riverpod
/// 直接跳过通知，一次普通 rebuild 不会连带重建两枚按钮。
@immutable
class ShellNavHistory {
  const ShellNavHistory({this.canGoBack = false, this.canGoForward = false});

  final bool canGoBack;
  final bool canGoForward;

  @override
  bool operator ==(Object other) =>
      other is ShellNavHistory &&
      other.canGoBack == canGoBack &&
      other.canGoForward == canGoForward;

  @override
  int get hashCode => Object.hash(canGoBack, canGoForward);
}

/// 中栏导航历史的可观察面：栏头两枚箭头读它决定能不能点。
final NotifierProvider<ShellNavHistoryController, ShellNavHistory>
shellNavHistoryProvider =
    NotifierProvider<ShellNavHistoryController, ShellNavHistory>(
      ShellNavHistoryController.new,
    );

/// [ShellNavHistory] 的唯一写入口，由 [ShellTargetController] 在每次导航后回写。
///
/// 单独拆一个 provider 而不是塞进 `shellTargetProvider` 的 state：后者是
/// `ShellTarget?`，八个调用点与两个测试替身都按它写；把栈塞进去会把一圈
/// 无关代码一起改掉，而"能不能退"又必须能被 watch 到。
class ShellNavHistoryController extends Notifier<ShellNavHistory> {
  @override
  ShellNavHistory build() => const ShellNavHistory();

  void sync({required bool canGoBack, required bool canGoForward}) {
    final next = ShellNavHistory(
      canGoBack: canGoBack,
      canGoForward: canGoForward,
    );
    if (next != state) {
      state = next;
    }
  }
}

/// 右栏（文件树 / 文件预览 / 面板开始页）认的项目目录。
///
/// 与 [shellTargetProvider] 分开记：录音、记忆这类工具页占着中栏但
/// **没有**项目归属，右栏不该因为中栏换了一页就退回"先选个项目"——
/// 那会让已经打开的仓库树与文件预览凭空消失，而终端还连着同一台机器。
/// 这里只记住最后一个有归属的项目，工具页期间右栏继续用它。
final NotifierProvider<ShellProjectMemoController, String>
shellProjectMemoProvider = NotifierProvider<ShellProjectMemoController, String>(
  ShellProjectMemoController.new,
);

class ShellProjectMemoController extends Notifier<String> {
  @override
  String build() {
    // 直接听目标本身：谁改的 `shellTargetProvider`（RailNavigator、新建会话、
    // 测试里的固定目标）都能收到，不必让导航控制器额外回写一次。
    ref.listen<ShellTarget?>(shellTargetProvider, (previous, next) {
      if (next == null) {
        // 关掉右侧 = 没有当前项目：右栏回到"先在左侧选择一个项目"。
        state = '';
        return;
      }
      if (next.projectId.isNotEmpty) {
        state = next.projectId;
      }
      // 工具页（空 projectId）保留上一个项目，右栏不动。
    });
    return ref.read(shellTargetProvider)?.projectId ?? '';
  }
}

/// 宽屏右侧要显示什么。切换模式时会清空：两个模式的数据互不相干，
/// 留着上一个模式的选中项只会让右侧显示一个当前模式根本看不到的对象。
final NotifierProvider<ShellTargetController, ShellTarget?>
shellTargetProvider = NotifierProvider<ShellTargetController, ShellTarget?>(
  ShellTargetController.new,
);

class ShellTargetController extends Notifier<ShellTarget?> {
  /// 历史深度上限。
  ///
  /// 一次导航的增删是 O(1)，`retitle` / 剪枝最多扫两倍的量，可以忽略；
  /// 加这个上限只是不让长时间的会话把内存一路堆上去。
  static const int historyLimit = 50;

  /// 退回去过的页面（越靠后越近）与它们被退掉之后还能再回来的页面。
  ///
  /// 两个栈都以 `ShellTarget?` 为元素：空态页也是一页，关掉会话回到空态
  /// 之后按后退应该能回到那个会话。
  final List<ShellTarget?> _back = <ShellTarget?>[];
  final List<ShellTarget?> _forward = <ShellTarget?>[];

  @override
  ShellTarget? build() => null;

  /// 选中一项：把当前页压入后退栈，并清空前进方向。
  ///
  /// 清空前进栈是浏览器 / VS Code 的既有语义：从这里分叉出去之后，
  /// 原来那条"往前"的路已经不属于新的浏览路径了。
  void select(ShellTarget target) {
    if (state == target) {
      return;
    }
    _record();
    state = target;
    _publish();
  }

  /// 关闭右侧：同样算一次导航，按后退能回到刚关掉的那一页。
  void clear() {
    if (state == null) {
      return;
    }
    _record();
    state = null;
    _publish();
  }

  /// 会话页「关闭 / 删除」后的落点：回到它所属的项目页。
  ///
  /// 目标里没带项目对象（历史数据、外部直达）时退回空状态：
  /// 与其把右侧留成一个已经不存在的会话，不如让用户从侧栏重选。
  void backToProject() {
    final current = state;
    final project = current is ConversationTarget ? current.project : null;
    final next = project == null ? null : ProjectTarget(project);
    if (next == state) {
      return;
    }
    _record();
    state = next;
    _publish();
  }

  /// 切换模式时调用：两个模式的数据互不相干，历史一起丢掉。
  ///
  /// 不能退化成 `clear()`——那会把"上一个模式的某一页"记进后退栈，
  /// 退回去就是一个当前模式根本看不到的对象。
  void reset() {
    _back.clear();
    _forward.clear();
    state = null;
    _publish();
  }

  /// 后退一页；没有可退的页面时返回 false 且什么都不做。
  bool goBack() {
    if (_back.isEmpty) {
      return false;
    }
    final target = _back.removeLast();
    _push(_forward, state);
    state = target;
    _publish();
    return true;
  }

  /// 前进一页；没有可前进的页面时返回 false 且什么都不做。
  bool goForward() {
    if (_forward.isEmpty) {
      return false;
    }
    final target = _forward.removeLast();
    _push(_back, state);
    state = target;
    _publish();
    return true;
  }

  /// 会话改名后同步 target：侧栏与栏头都读这一份，不换实例就还是旧标题。
  ///
  /// 历史里同一个会话的条目也一起换标题，否则后退回去栏头还是旧名字。
  void retitle(String conversationId, String title) {
    final next = _retitled(state, conversationId, title);
    if (!identical(next, state)) {
      state = next;
    }
    _retitleIn(_back, conversationId, title);
    _retitleIn(_forward, conversationId, title);
  }

  /// 会话被删掉之后从历史里剪掉它。
  ///
  /// 调用方要**先**导航（`backToProject`）再剪枝：导航会把当前这一页压进
  /// 后退栈，先剪会把刚压进去的那条又留下，后退就落到一个已经不存在的东西上。
  void forgetConversation(String conversationId) {
    bool stale(ShellTarget? target) =>
        target is ConversationTarget && target.conversationId == conversationId;
    _drop(_back, stale);
    _drop(_forward, stale);
    _publish();
  }

  /// 项目被删掉之后从历史里剪掉它名下的所有页面（含它的会话与任务）。
  ///
  /// 顺序要求同 [forgetConversation]：先导航再剪枝。
  void forgetProject(String projectId) {
    bool stale(ShellTarget? target) => target?.projectId == projectId;
    _drop(_back, stale);
    _drop(_forward, stale);
    _publish();
  }

  /// 录音被删掉之后从历史里剪掉它的详情页。
  ///
  /// 顺序要求同 [forgetConversation]：先导航（回到列表）再剪枝，
  /// 反过来会把刚压进后退栈的那一条又留下，后退就落到一个已经删掉的录音上。
  void forgetRecording(String recordingKey) {
    if (recordingKey.isEmpty) {
      return;
    }
    bool stale(ShellTarget? target) =>
        target is RecordingDetailTarget && target.key == recordingKey;
    _drop(_back, stale);
    _drop(_forward, stale);
    _publish();
  }

  /// 记一条历史：旧页入后退栈，前进方向作废。
  void _record() {
    _push(_back, state);
    _forward.clear();
  }

  void _push(List<ShellTarget?> stack, ShellTarget? target) {
    stack.add(target);
    if (stack.length > historyLimit) {
      stack.removeAt(0);
    }
  }

  void _drop(List<ShellTarget?> stack, bool Function(ShellTarget?) stale) {
    stack.removeWhere(stale);
  }

  void _retitleIn(
    List<ShellTarget?> stack,
    String conversationId,
    String title,
  ) {
    for (var i = 0; i < stack.length; i++) {
      stack[i] = _retitled(stack[i], conversationId, title);
    }
  }

  /// 把 [target] 换成带新标题的实例；不是这个会话 / 标题没变时原样返回。
  ShellTarget? _retitled(
    ShellTarget? target,
    String conversationId,
    String title,
  ) {
    if (target is! ConversationTarget ||
        target.conversationId != conversationId ||
        target.title == title) {
      return target;
    }
    return ConversationTarget(
      projectId: target.projectId,
      conversationId: target.conversationId,
      title: title,
      projectPath: target.projectPath,
      project: target.project,
    );
  }

  /// 把栈的可用状态回写给栏头按钮。
  ///
  /// 只在导航方法里调用，绝不在 `build()` 期间写：那会在构建阶段改另一个
  /// provider 的状态，Riverpod 会直接抛异常。
  void _publish() {
    ref
        .read(shellNavHistoryProvider.notifier)
        .sync(canGoBack: _back.isNotEmpty, canGoForward: _forward.isNotEmpty);
  }
}
