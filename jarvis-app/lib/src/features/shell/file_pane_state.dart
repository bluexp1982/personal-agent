import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/preview_source.dart';
import 'chat_window_state.dart';
import 'panel_fullscreen.dart';
import 'shell_layout_state.dart';
import 'immersive_fullscreen.dart';

/// 右侧栏默认宽度。
///
/// 400 而不是更窄：面板现在要同时承载文件树、文件预览与终端，
/// 320 那档在终端里连 80 列都放不下，每次都得先拖宽再敲命令。
const double kFilePaneWidth = 400;

/// 拖动下限：再窄就放不下「缩进 + 文件名 + 大小」这三段信息。
///
/// 与左栏口径一致：拖到它以下不会"卡住"，也不会立刻收起——宽度先冻结在
/// 最后一个合法值，要继续按住拖满 `kCollapseHoldDuration` 才收起。
/// 收起后手势不中断，反向回拉 `kSashReopenPull` 就能按原宽度拉回来。
const double kFilePaneMinWidth = 320;

/// 拖动上限：面板最宽可以占掉大半窗口，但总要给中间会话区留一条可读的宽度。
const double kFilePaneMaxWidth = 900;

/// 右侧栏拖动条命中区宽度。视觉上仍是 1px 细线。
const double kFilePaneHandleWidth = 8;

/// 右栏左边缘拖动条的 Key。
const Key kFilePaneResizeHandleKey = Key('shell-file-pane-resize-handle');

/// 中栏栏头右侧的开合按钮 Key。
///
/// 只在面板关闭时存在：面板打开后入口收到面板自己的工具条里，
/// 同一屏不出现两个"开 / 关面板"的按钮。
const Key kFilePaneToggleKey = Key('shell-file-pane-toggle');

/// 面板工具条里的全屏按钮 Key（进入后变成"退出全屏"，同一个按钮）。
const Key kFilePaneFullscreenKey = Key('shell-file-pane-fullscreen');

/// 面板工具条里的隐藏按钮 Key。
///
/// 与中栏的 [kFilePaneToggleKey] 分开：两者虽然都改变显隐，
/// 但一个在面板里、一个在面板外，测试与无障碍定位不能互相命中。
const Key kFilePaneHideKey = Key('shell-file-pane-hide');

/// 面板标签的 Key。
///
/// 标签改成"插入顺序的列表"之后，一个标签的身份是 `(kind, id)` 而不是 kind：
/// 空白页、浏览器、预览都能同时存在多份。同一个父级下的兄弟不能共用 Key，
/// 测试也要能精确命中"第几个浏览器标签"，所以统一按 kind + id 生成。
Key panelTabKey(PanelTabRef tab) =>
    ValueKey<String>('shell-panel-tab:${tab.kind.name}:${tab.id}');

/// 初始空白页（「新标签页」）的 id。
const String kInitialPanelTabId = 'start-1';

/// 单例标签（文件树 / 终端）的固定 id：它们各只有一份，id 因此是常量。
const String kPanelFilesTabId = 'panel-files';
const String kPanelTerminalTabId = 'panel-terminal';
const String kPanelGitTabId = 'panel-git';

/// 这一套 Key 是给测试与无障碍定位用的稳定锚点，全部派生自 [panelTabKey]：
/// 只有同一个来源，`find.byKey` 才不会因为改名而与标签栏里的实际 Key 失配。
final Key kPanelStartTabKey = panelTabKey(
  const PanelTabRef.start(kInitialPanelTabId),
);
final Key kPanelFilesTabKey = panelTabKey(const PanelTabRef.files());
final Key kPanelTerminalTabKey = panelTabKey(const PanelTabRef.terminal());
final Key kPanelGitTabKey = panelTabKey(const PanelTabRef.git());

/// 面板里某个浏览器标签的 Key。
Key panelBrowserTabKey(String id) => panelTabKey(PanelTabRef.browser(id));

/// 预览标签的 Key：一个文件一个标签，所以按路径生成。
Key panelPreviewTabKey(String path) => panelTabKey(PanelTabRef.preview(path));

/// 标签栏末尾「+」按钮的 Key。
const Key kPanelNewTabKey = Key('shell-panel-new-tab');

/// 「+」按钮占的宽度。与栏头其它图标按钮同一口径，不算进标签宽度预算。
const double kPanelTabAddButtonSize = kPaneHeaderButtonSize;

/// 标签宽度区间：少时保底 96（太窄的块看起来像残次品），多时最宽 180。
///
/// 与 Codex 的标签条一致：宽度由"当前有几个标签 + 面板有多宽"算出来，
/// 而不是各自跟着文字长短伸缩——那样切标签时整条栏都在跳。
const double kPanelTabMinWidth = 96;
const double kPanelTabMaxWidth = 180;

/// 标签之间的缝。
const double kPanelTabGap = 4;

/// 标签之间那条浅灰竖线的尺寸。
///
/// 线画在 [kPanelTabGap] 这条缝里，不额外占宽度：标签宽度是按
/// `available - kPanelTabGap * (count - 1)` 算的，线一旦占位，
/// `panelTabWidth` 与"切标签时整条栏不跳"的约束都得跟着改。
const double kPanelTabDividerWidth = 1;
const double kPanelTabDividerHeight = 14;

/// 第 [index] 个标签左侧分隔线的 Key（索引从 1 开始，第一个标签前没有线）。
///
/// 每根线必须各用各的 Key：同一个父级下的兄弟不能共用 Key，
/// 测试也要能逐根断言"哪根该在、哪根该不在"，而不是只找到其中一根。
/// 当前标签左右两侧那两根不出线，因此能被找到的线至多是"标签数 - 3"根。
Key panelTabDividerKey(int index) =>
    ValueKey<String>('shell-panel-tab-divider:$index');

/// 标签里关闭按钮的槽宽。
///
/// 槽位常驻、只切换可见性：非当前标签在悬停时才显示关闭叉，
/// 如果那时才插入按钮，文字会被挤窄、整条标签跟着抖一下。
const double kPanelTabCloseSize = 16;

/// 标签里图标的尺寸。
///
/// 内置图标与站点图标共用这一格：favicon 到位后原地替换，标签宽度与文字位置都不动。
const double kPanelTabIconSize = 13;

/// 空白页（「+」新开的那一张）在标签栏上的名字。
///
/// 与浏览器空白页的默认标题是同一句话，但刻意各留一份常量：
/// 两者是不同能力的占位文案，改一处不该顺手改掉另一处。
const String kPanelBlankTabLabel = '新标签页';

/// 按可用宽度算每个标签的槽宽。
///
/// `raw < kPanelTabMinWidth` 说明标签多到放不下：这时按 `raw` 平分而不是抬到最小值，
/// 抬上去必然溢出。于是"少则最小宽度、多则平铺"两种形态一次算清，
/// 不需要横向滚动，也就不会出现"滚动位置莫名其妙变了"的体验。
double panelTabWidth({required double available, required int count}) {
  if (count <= 0) {
    return 0;
  }
  final raw = (available - kPanelTabGap * (count - 1)) / count;
  if (raw <= 0) {
    return 0;
  }
  return raw > kPanelTabMaxWidth ? kPanelTabMaxWidth : raw;
}

/// 由横向坐标反算命中的标签下标。
///
/// 标签排布是 `[tab][gap][tab][gap]…`，`step = tabWidth + kPanelTabGap`。
/// 标签栏的右键菜单只有一个锚点（整条栏一个 `MenuAnchor`），
/// 靠这个函数把落点换算成"被点的那个标签"，才知道该按谁的可用性出菜单。
///
/// - 落在标签内：直接是它；
/// - 落在 4dp 的缝里：取更近的一侧（缝太窄，猜哪边都合理）；
/// - 落在最后一个标签右边（拖动区、全屏/隐藏按钮）：返回 null，不弹菜单。
int? panelTabIndexAt({
  required double dx,
  required double tabWidth,
  required int count,
}) {
  if (count <= 0 || tabWidth <= 0 || dx < 0) {
    return null;
  }
  final step = tabWidth + kPanelTabGap;
  final index = dx ~/ step;
  if (index < 0 || index >= count) {
    return null;
  }

  final offsetInSlot = dx - index * step;
  if (offsetInSlot <= tabWidth) {
    return index;
  }
  // 缝里：靠近后一个就归后一个，但没有后一个时必须归前一个。
  final inGap = offsetInSlot - tabWidth;
  return inGap < kPanelTabGap / 2 || index + 1 >= count ? index : index + 1;
}

/// 把右栏宽度收敛到当前内容区真正允许的区间。
///
/// `available` 是「中间内容 + 拖动条 + 右栏」的总宽度。放不下时返回 0，
/// 由调用方整栏不渲染：宁可让用户去拉宽窗口，也不要把中间会话挤成一条缝。
double fitFilePaneWidth({required double width, required double available}) {
  final limit = available - kPaneMinWidth - kFilePaneHandleWidth;
  if (limit < kFilePaneMinWidth) {
    return 0;
  }

  final upper = math.min(limit, kFilePaneMaxWidth);
  return width.clamp(kFilePaneMinWidth, upper).toDouble();
}

/// 右栏是否显示。默认收起，保持现有两栏布局不变。
final NotifierProvider<FilePaneVisibleController, bool>
filePaneVisibleProvider = NotifierProvider<FilePaneVisibleController, bool>(
  FilePaneVisibleController.new,
);

class FilePaneVisibleController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() {
    if (state) {
      hide();
    } else {
      show();
    }
  }

  /// 显示面板。标签被关光时先补一张空白页再显示：
  /// 空列表意味着"右栏已经自己收起了"，这里不补页会露出一条没有内容的栏。
  void show() {
    ref.read(filePaneTabProvider.notifier).ensureTabPage();
    state = true;
  }

  /// 收起面板，并顺手退出两种全屏。
  ///
  /// 面板全屏的含义是"面板吃掉中栏"，面板都收起了还留着标记的话，
  /// 下次打开面板会直接铺满中间区，看起来像掉进了另一个模式。
  ///
  /// 终端全屏更彻底：它连标签栏与左栏都藏了，收起面板之后现场没有任何
  /// 出口，必须在这里把窗口也一起还原（`HomeShell` 也有一条同样的兜底）。
  void hide() {
    ref.read(panelFullscreenProvider.notifier).exit();
    ref.read(immersiveFullscreenProvider.notifier).exit();
    state = false;

    // 右栏一走，中栏就是唯一的内容区；这时如果聊天还浮在上面，中栏也得给它让位
    // （见 `_WideContent`），屏幕正中就只剩一块浮窗压着空白，用户连"聊天回哪儿了"
    // 都要自己找。所以收起右栏时顺手把浮窗停靠回中栏——浮窗本来就只在右栏打开时
    // 才给入口（见 `chat_page` 的栏头），右栏没了，这个形态也就没有理由留着。
    //
    // 放在状态层而不是各个按钮里：收起右栏的入口有四个（面板里的隐藏按钮、
    // 拖窄蓄力收起、关掉最后一个标签、窗口放不下时自动收起），逐个挂一遍
    // 迟早漏一个。
    final chat = ref.read(chatWindowProvider);
    final pinned = chat.pinned;
    if (chat.floating && pinned != null) {
      ref.read(chatWindowProvider.notifier).dock();
      ref.read(shellTargetProvider.notifier).select(pinned);
    }
  }
}

/// 用户拖出来的右栏宽度。与显隐分开存：收起再展开要回到原来的宽度。
final NotifierProvider<FilePaneWidthController, double> filePaneWidthProvider =
    NotifierProvider<FilePaneWidthController, double>(
      FilePaneWidthController.new,
    );

class FilePaneWidthController extends Notifier<double> {
  @override
  double build() => kFilePaneWidth;

  /// 收下拖动产生的绝对宽度（调用方已经收敛过）。
  void resize(double width) => state = width;
}

/// 是否显示 `.` 开头的隐藏项。只影响文件树，不影响目录选择器。
final NotifierProvider<FilePaneShowHiddenController, bool>
filePaneShowHiddenProvider =
    NotifierProvider<FilePaneShowHiddenController, bool>(
      FilePaneShowHiddenController.new,
    );

class FilePaneShowHiddenController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

/// 已展开目录的路径集合。键是服务端返回的绝对路径。
final NotifierProvider<FilePaneExpandedController, Set<String>>
filePaneExpandedProvider =
    NotifierProvider<FilePaneExpandedController, Set<String>>(
      FilePaneExpandedController.new,
    );

class FilePaneExpandedController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void toggle(String path) {
    final next = Set<String>.of(state);
    if (!next.remove(path)) {
      next.add(path);
    }
    state = next;
  }

  /// 切换项目时调用：旧目录的展开状态对新项目没有意义。
  void collapseAll() => state = const <String>{};
}

/// 右栏标签。`start` 是空白「新标签页」（原来的开始页），`files` 是文件树，
/// `preview` 是文件内容，`terminal` 是 SSH 终端（原来独立成一个顶栏模式，
/// 现在只是面板里的一项能力），`browser` 是浏览器（本机 / 服务器 / 互联网
/// 三种来源，一个标签一页、可多开），`git` 是仓库面板（审查变更与本地提交）。
enum FilePaneTab { start, files, preview, terminal, browser, git }

/// 一个标签的稳定身份。
///
/// [FilePaneTab] 只够表达"哪一类"，表达不了"这一类里的哪一个"——空白页、预览、
/// 浏览器都能同时存在多份，右键菜单要按"被点的那个标签"算左右邻居，就必须带上 id。
/// 文件与终端是单例能力，但同样给固定 id：这样整条标签栏（以及关闭、激活、
/// key 生成）都只走"按 id 找标签"一条路径，不需要为单例写特例。
@immutable
class PanelTabRef {
  const PanelTabRef({required this.kind, required this.id});

  /// 空白「新标签页」。[id] 由控制器递增生成（`start-1`、`start-2`……）。
  const PanelTabRef.start(this.id) : kind = FilePaneTab.start;

  const PanelTabRef.files() : kind = FilePaneTab.files, id = kPanelFilesTabId;

  const PanelTabRef.terminal()
    : kind = FilePaneTab.terminal,
      id = kPanelTerminalTabId;

  const PanelTabRef.git() : kind = FilePaneTab.git, id = kPanelGitTabId;

  const PanelTabRef.browser(this.id) : kind = FilePaneTab.browser;

  /// 预览的 id 就是服务端绝对路径（与 [FilePreviewTab.path] 同一口径）。
  const PanelTabRef.preview(this.id) : kind = FilePaneTab.preview;

  /// 按类别取标签。空白页 / 预览 / 浏览器必须带上各自的 id：
  /// 它们的身份还包含"是哪一页"。
  factory PanelTabRef.of(FilePaneTab kind, {String? id}) {
    return switch (kind) {
      FilePaneTab.start => PanelTabRef.start(id ?? kInitialPanelTabId),
      FilePaneTab.files => const PanelTabRef.files(),
      FilePaneTab.terminal => const PanelTabRef.terminal(),
      FilePaneTab.git => const PanelTabRef.git(),
      FilePaneTab.browser => PanelTabRef.browser(id ?? ''),
      FilePaneTab.preview => PanelTabRef.preview(id ?? ''),
    };
  }

  final FilePaneTab kind;

  /// 空白页与浏览器是本地序号，预览是绝对路径，文件 / 终端是固定常量。
  final String id;

  /// 是不是一张还没选功能的空白页。只有空白页能被"原位转换"成别的标签。
  bool get isBlank => kind == FilePaneTab.start;

  @override
  bool operator ==(Object other) =>
      other is PanelTabRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// 一个已打开的文件预览标签。
///
/// 一个文件对应一个标签：同一路径重复打开只会"定位回已有标签"，不会堆出两份。
@immutable
class FilePreviewTab {
  const FilePreviewTab({required this.path, required this.title});

  /// 服务端绝对路径，同时充当标签的身份。
  final String path;

  /// 标签上显示的名字（文件名）。
  final String title;

  @override
  bool operator ==(Object other) =>
      other is FilePreviewTab && other.path == path && other.title == title;

  @override
  int get hashCode => Object.hash(path, title);
}

/// 标签状态：一张**按插入顺序**排列的标签列表 + 当前活动标签的 id。
///
/// 为什么是"一张列表"而不是"每类一个字段"：空白页能被原位转换（选「项目文件」
/// 就当场变成文件标签），顺序又必须是用户打开 / 转换时的顺序，只有一张列表能同时
/// 表达这两件事。以前的 `filesOpen` / `terminalOpen` / `browserTabs` / `previews`
/// 全部降级成派生 getter，避免两份状态各自演化后不同步。
///
/// 列表可以为空——空列表就是"右栏没有内容"，由界面层收起整栏（再打开时补一张
/// 空白页，见 `FilePaneVisibleController.show`）。
@immutable
class FilePaneTabState {
  const FilePaneTabState({
    this.tabs = const <PanelTabRef>[PanelTabRef.start(kInitialPanelTabId)],
    this.activeId = kInitialPanelTabId,
    this.previewTitles = const <String, String>{},
    this.previewSources = const <String, PreviewSource>{},
  });

  /// 标签列表。下标即标签栏里的位置。
  final List<PanelTabRef> tabs;

  /// 当前标签的 id；列表为空时为 null。
  final String? activeId;

  /// 预览标签的显示名（键是标签 id：项目文件是路径，媒体是 `media:<id>`）。
  ///
  /// 单独存一张表而不是塞进 [PanelTabRef]：标签身份只该包含"是哪一页"，
  /// 而标题会随文件真实名字更新，混进身份里会让"同一个文件的标签"变成两个。
  final Map<String, String> previewTitles;

  /// 预览标签的内容来源（键同 [previewTitles]）。
  ///
  /// 没有登记时按"项目文件、项目取当前 shell 目标"处理——文件树打开的标签
  /// 一直走这条隐式路径，保持兼容。会话产物进右栏时由 [openMediaPreview] /
  /// [openPreview] 显式登记，因为媒体没有项目路径、另一个项目的文件也可能
  /// 从会话里打开。
  final Map<String, PreviewSource> previewSources;

  bool get isEmpty => tabs.isEmpty;

  /// 当前标签。活动 id 失效时退化成第一个，绝不返回"看起来什么都没选"的状态。
  PanelTabRef? get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeId) {
        return tab;
      }
    }
    return tabs.isEmpty ? null : tabs.first;
  }

  /// 当前标签的类别；空列表时为 null。
  FilePaneTab? get active => activeTab?.kind;

  bool get filesOpen => tabs.any((tab) => tab.kind == FilePaneTab.files);

  bool get terminalOpen => tabs.any((tab) => tab.kind == FilePaneTab.terminal);

  bool get gitOpen => tabs.any((tab) => tab.kind == FilePaneTab.git);

  /// 已打开的浏览器标签 id，按插入顺序排列。
  ///
  /// 只存 id：会话（通道、地址、标题、图标）由
  /// `browserSessionProvider(id)` 各自持有，这里不管资源。
  List<String> get browserTabs => <String>[
    for (final tab in tabs)
      if (tab.kind == FilePaneTab.browser) tab.id,
  ];

  /// 当前标签是浏览器时返回它的 id，否则 null。
  String? get activeBrowserId {
    final tab = activeTab;
    return tab != null && tab.kind == FilePaneTab.browser ? tab.id : null;
  }

  /// 已打开的预览，按插入顺序排列。
  List<FilePreviewTab> get previews => <FilePreviewTab>[
    for (final tab in tabs)
      if (tab.kind == FilePaneTab.preview)
        FilePreviewTab(path: tab.id, title: previewTitle(tab.id)),
  ];

  /// 当前标签是预览时返回它的路径，否则 null。
  String? get activePreviewPath {
    final tab = activeTab;
    return tab != null && tab.kind == FilePaneTab.preview ? tab.id : null;
  }

  bool get hasPreview => tabs.any((tab) => tab.kind == FilePaneTab.preview);

  /// 当前显示的预览；不在预览标签上时为 null。
  FilePreviewTab? get activePreview {
    final path = activePreviewPath;
    if (path == null) {
      return null;
    }
    return FilePreviewTab(path: path, title: previewTitle(path));
  }

  bool isPreviewActive(String path) =>
      activeTab?.kind == FilePaneTab.preview && activeId == path;

  bool isBrowserActive(String id) =>
      activeTab?.kind == FilePaneTab.browser && activeId == id;

  /// 预览标签的显示名。[previewTitles] 里没有时退化成文件名，
  /// 这样即便标题表被重建也不会出现一条没有名字的空标签。
  String previewTitle(String path) {
    final title = previewTitles[path];
    if (title != null && title.isNotEmpty) {
      return title;
    }
    final slash = path.lastIndexOf('/');
    return slash >= 0 && slash + 1 < path.length
        ? path.substring(slash + 1)
        : path;
  }

  /// 预览标签的来源；没登记时返回 null（按项目文件处理）。
  PreviewSource? previewSourceOf(String tabId) => previewSources[tabId];

  FilePaneTabState copyWith({
    List<PanelTabRef>? tabs,
    String? activeId,
    Map<String, String>? previewTitles,
    Map<String, PreviewSource>? previewSources,
  }) {
    return FilePaneTabState(
      tabs: tabs ?? this.tabs,
      activeId: activeId ?? this.activeId,
      previewTitles: previewTitles ?? this.previewTitles,
      previewSources: previewSources ?? this.previewSources,
    );
  }
}

/// 标签顺序与"相对某个标签的邻居"查询。
///
/// 右键菜单的「关闭其他 / 关闭左侧 / 关闭右侧」本质都是"按视觉顺序取一段集合"，
/// 把这段逻辑放在状态层而不是菜单里：菜单只负责展示与回调，集合错了能靠单测直接抓到。
extension PanelTabStateQuery on FilePaneTabState {
  /// 标签在栏里的视觉顺序。
  ///
  /// 标签改成插入顺序之后，它**就是** [tabs] 本身；保留这个名字是因为界面层与
  /// 菜单都按"视觉顺序"来读，换成 `tabs` 会让"顺序"这层语义散落在各处。
  List<PanelTabRef> get orderedTabs => tabs;

  bool isTabActive(PanelTabRef tab) => tab.id == activeId;

  /// 除 [anchor] 之外的所有标签（空白页也可被关掉，没有豁免）。
  List<PanelTabRef> otherTabs(PanelTabRef anchor) => <PanelTabRef>[
    for (final tab in orderedTabs)
      if (tab != anchor) tab,
  ];

  /// [anchor] 左侧的全部标签。
  List<PanelTabRef> tabsBefore(PanelTabRef anchor) {
    final index = orderedTabs.indexOf(anchor);
    if (index <= 0) {
      return const <PanelTabRef>[];
    }
    return orderedTabs.take(index).toList();
  }

  /// [anchor] 右侧的全部标签。
  List<PanelTabRef> tabsAfter(PanelTabRef anchor) {
    final index = orderedTabs.indexOf(anchor);
    if (index < 0) {
      return const <PanelTabRef>[];
    }
    return orderedTabs.skip(index + 1).toList();
  }
}

final NotifierProvider<FilePaneTabController, FilePaneTabState>
filePaneTabProvider = NotifierProvider<FilePaneTabController, FilePaneTabState>(
  FilePaneTabController.new,
);

class FilePaneTabController extends Notifier<FilePaneTabState> {
  /// 浏览器标签 id 的本地序号。
  ///
  /// 单调递增、不回收：关掉再新建时复用旧 id 会让 family provider 的
  /// "旧会话已释放"与"新会话"撞在同一个 key 上。
  int _browserSeq = 0;

  /// 空白页 id 的本地序号。从 1 起：初始状态已经占掉 `start-1`。
  int _startSeq = 1;

  @override
  FilePaneTabState build() => const FilePaneTabState();

  /// 「+」：在标签栏末尾追加一张空白页并激活它，返回新标签的 id。
  ///
  /// 空白页可以有多张：用户可能同时开着好几张"待选功能"的页，
  /// 这与浏览器里连点几次新建标签页是同一种心智。
  String openNewTabPage() {
    final id = _nextStartId();
    state = FilePaneTabState(
      tabs: <PanelTabRef>[...state.tabs, PanelTabRef.start(id)],
      activeId: id,
      previewTitles: state.previewTitles,
      previewSources: state.previewSources,
    );
    return id;
  }

  /// 切到指定标签。id 不存在时什么也不做（菜单与回调可能持有过期锚点）。
  void activate(String id) {
    if (!state.tabs.any((tab) => tab.id == id)) {
      return;
    }
    state = state.copyWith(activeId: id);
  }

  /// 打开文件标签（单例）。
  ///
  /// [intoTabId] 是"从哪张空白页点进来的"：已经开着就关掉那张空白页、把焦点
  /// 交给已有标签；没开过就让它原位变成文件标签——用户看到的是"这一页换成了
  /// 文件树"，而不是旁边又多出一个标签。
  void openFiles({String? intoTabId}) {
    if (state.filesOpen) {
      _reveal(kPanelFilesTabId, dropping: intoTabId);
      return;
    }
    _openInto(const PanelTabRef.files(), intoTabId: intoTabId);
  }

  /// 打开终端标签（单例）。已经开过就只是切回去：终端会话在
  /// `sshControllerProvider` 里保活，重复点击不该重置滚动缓冲或重新握手。
  void openTerminal({String? intoTabId}) {
    if (state.terminalOpen) {
      _reveal(kPanelTerminalTabId, dropping: intoTabId);
      return;
    }
    _openInto(const PanelTabRef.terminal(), intoTabId: intoTabId);
  }

  /// 打开 Git 面板（单例）。
  ///
  /// 与终端同一口径：已经开着就只切回那个标签。git 面板里的状态（正在看哪份
  /// diff、提交框里写到一半的信息）由面板自己持有，重复点击不该把它清空。
  void openGit({String? intoTabId}) {
    if (state.gitOpen) {
      _reveal(kPanelGitTabId, dropping: intoTabId);
      return;
    }
    _openInto(const PanelTabRef.git(), intoTabId: intoTabId);
  }

  /// 关闭 Git 面板标签。
  void closeGit() => closeTab(const PanelTabRef.git());

  /// 打开一个文件：没开过就新开一个标签，已经开着就只把焦点切过去。
  ///
  /// 同一个文件重复点击不该堆出两份标签——那会让人以为"内容没刷新"，
  /// 而实际上两份标签指向同一份内容，关掉其中一份还要猜哪份是活的。
  void openPreview({
    required String path,
    required String title,
    String? projectId = '',
    String? intoTabId,
  }) {
    // 标题可能从占位值变成真实文件名：顺手更新已有标签。
    final titles = <String, String>{...state.previewTitles, path: title};
    // 从会话里打开的产物带上了自己的项目 id：右栏此刻的 shell 目标可能
    // 不是那个项目（窄屏整页形态尤其如此），不能靠隐式回退。
    final sources = <String, PreviewSource>{
      ...state.previewSources,
      if (projectId != null && projectId.isNotEmpty)
        path: PreviewSource.file(projectId: projectId, path: path),
    };
    final existing = state.tabs.any(
      (tab) => tab.kind == FilePaneTab.preview && tab.id == path,
    );
    if (existing) {
      _reveal(
        path,
        dropping: intoTabId,
        previewTitles: titles,
        previewSources: sources,
      );
      return;
    }
    _openInto(
      PanelTabRef.preview(path),
      intoTabId: intoTabId,
      previewTitles: titles,
      previewSources: sources,
    );
  }

  /// 打开一枚会话产物（图片 / 视频）的预览。
  ///
  /// 标签 id 用 `media:<assetId>`：与项目文件路径天然区分，同一个资产重复点开
  /// 只切标签；来源里带上资产与会话标题，预览页据此取字节、另存时才能自动命名。
  void openMediaPreview({
    required MediaAsset asset,
    required String title,
    String conversationTitle = '',
    String? intoTabId,
  }) {
    final id = PreviewSource.mediaTabId(asset.id);
    final titles = <String, String>{...state.previewTitles, id: title};
    final sources = <String, PreviewSource>{
      ...state.previewSources,
      id: PreviewSource.media(
        asset: asset,
        conversationTitle: conversationTitle,
      ),
    };
    final existing = state.tabs.any(
      (tab) => tab.kind == FilePaneTab.preview && tab.id == id,
    );
    if (existing) {
      _reveal(
        id,
        dropping: intoTabId,
        previewTitles: titles,
        previewSources: sources,
      );
      return;
    }
    _openInto(
      PanelTabRef.preview(id),
      intoTabId: intoTabId,
      previewTitles: titles,
      previewSources: sources,
    );
  }

  /// 切到一个已经打开的预览标签（标签栏点击用）。
  void activatePreview(String path) {
    if (!state.tabs.any(
      (tab) => tab.kind == FilePaneTab.preview && tab.id == path,
    )) {
      return;
    }
    activate(path);
  }

  /// 每次点击都新开一个浏览器标签，返回新标签的 id。
  ///
  /// 与终端 / 预览不同，这里**不复用**已有标签：浏览器的语义是"新开一页"，
  /// 用户点第二下要的就是另一个页面（可能连着另一个服务）。要切回旧页面
  /// 就点标签栏里那个标签，走 [activateBrowser]。
  ///
  /// id 只在本地递增，不落盘也不跨会话：标签本身就是会话级的，
  /// 重启后不存在"重现上次那个标签"这回事。
  String openNewBrowser({String? intoTabId}) {
    // 跳过还活着的 id：序号本身是单调的，但控制器若被重建会归零，
    // 撞上已存在的 id 会让标签栏出现重复 Key。
    String id;
    do {
      id = 'browser-${++_browserSeq}';
    } while (state.tabs.any((tab) => tab.id == id));

    _openInto(PanelTabRef.browser(id), intoTabId: intoTabId);
    return id;
  }

  /// 切到一个已经打开的浏览器标签（标签栏点击用）。
  void activateBrowser(String id) {
    if (!state.tabs.any(
      (tab) => tab.kind == FilePaneTab.browser && tab.id == id,
    )) {
      return;
    }
    activate(id);
  }

  /// 关闭单个标签。[closeTabs] 才是真正实现，这里只是"关一项"的语法糖。
  void closeTab(PanelTabRef tab) => closeTabs(<PanelTabRef>[tab]);

  /// 关闭指定 id 的空白页（「新标签页」）。空白页之间只差 id，
  /// 所以按 id 关，不能按类别关。
  void closeStartTab(String id) => closeTab(PanelTabRef.start(id));

  /// 关闭指定文件的预览标签。
  void closePreview(String path) => closeTab(PanelTabRef.preview(path));

  /// 关闭指定的浏览器标签。通道与静态服务由调用方释放——
  /// provider 不该知道传输层怎么收尾。
  void closeBrowserTab(String id) => closeTab(PanelTabRef.browser(id));

  /// 关闭终端标签。断开 SSH 由调用方负责——provider 不该知道连接层怎么收尾。
  void closeTerminal() => closeTab(const PanelTabRef.terminal());

  /// 关闭文件标签（目录树本身没有需要清理的状态，下次打开还是原来的展开集合）。
  void closeFiles() => closeTab(const PanelTabRef.files());

  /// 一次关掉一批标签（右键菜单的关闭 / 关闭其他 / 关闭左侧 / 关闭右侧）。
  ///
  /// 做成一次状态迁移而不是循环调单关：
  /// - 循环会触发多次重建，中间态还会按"左邻优先"把焦点来回搬一遍，
  ///   批量关三四个标签时能看到焦点在别的标签上闪一下；
  /// - 逐个关时"活动标签被关掉后回落到谁"取决于上一步的结果，
  ///   批量场景下这个依赖没有意义，用户要的是"回到被关区域旁边最近还活着的那个"。
  ///
  /// 回落的优先级：左邻 → 右邻 → 空列表。关到最后一个就交出空列表，
  /// 由界面层据此收起整栏（见 `ProjectPanel`）。
  void closeTabs(Iterable<PanelTabRef> targets) {
    final closing = targets.toSet();
    if (closing.isEmpty) {
      return;
    }

    final order = state.orderedTabs;
    final remaining = <PanelTabRef>[
      for (final tab in order)
        if (!closing.contains(tab)) tab,
    ];
    if (remaining.length == order.length) {
      return;
    }

    final activeIndex = order.indexWhere((tab) => tab.id == state.activeId);
    String? nextId;
    if (activeIndex >= 0 && !closing.contains(order[activeIndex])) {
      nextId = state.activeId;
    } else {
      for (var i = activeIndex - 1; i >= 0 && nextId == null; i--) {
        if (!closing.contains(order[i])) {
          nextId = order[i].id;
        }
      }
      for (var i = activeIndex + 1; i < order.length && nextId == null; i++) {
        if (!closing.contains(order[i])) {
          nextId = order[i].id;
        }
      }
      if (nextId == null && remaining.isNotEmpty) {
        nextId = remaining.first.id;
      }
    }

    // 关掉的预览不该把标题留在表里：那张表跟着状态一直活着，留着就是幽灵数据。
    final survivingPreviews = <String>{
      for (final tab in remaining)
        if (tab.kind == FilePaneTab.preview) tab.id,
    };
    state = FilePaneTabState(
      tabs: remaining,
      activeId: nextId,
      previewTitles: <String, String>{
        for (final entry in state.previewTitles.entries)
          if (survivingPreviews.contains(entry.key)) entry.key: entry.value,
      },
      previewSources: <String, PreviewSource>{
        for (final entry in state.previewSources.entries)
          if (survivingPreviews.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  /// 切到已有标签，并顺手把"从哪张空白页点进来"的那张关掉。
  ///
  /// 单例能力（文件 / 终端）与已开的预览都走这里：用户要的是"看到那个功能"，
  /// 不是"多出一个同样的标签"，更不该出现两个终端争同一个 SSH 会话。
  void _reveal(
    String id, {
    String? dropping,
    Map<String, String>? previewTitles,
    Map<String, PreviewSource>? previewSources,
  }) {
    final dropId = dropping == id ? null : dropping;
    state = FilePaneTabState(
      tabs: <PanelTabRef>[
        for (final tab in state.tabs)
          if (dropId == null || tab.id != dropId) tab,
      ],
      activeId: id,
      previewTitles: previewTitles ?? state.previewTitles,
      previewSources: previewSources ?? state.previewSources,
    );
  }

  /// 把 [intoTabId] 这张空白页原位换成 [target]；没有可转换的空白页就追加到末尾。
  ///
  /// 只认空白页：正常调用都以 `PanelStartView` 的 tabId 传入，非空白页
  /// （比如以后从其它页跳功能）不该被悄悄换掉。
  void _openInto(
    PanelTabRef target, {
    String? intoTabId,
    Map<String, String>? previewTitles,
    Map<String, PreviewSource>? previewSources,
  }) {
    final tabs = <PanelTabRef>[];
    var replaced = false;
    for (final tab in state.tabs) {
      if (!replaced &&
          intoTabId != null &&
          tab.id == intoTabId &&
          tab.isBlank) {
        tabs.add(target);
        replaced = true;
      } else {
        tabs.add(tab);
      }
    }
    if (!replaced) {
      tabs.add(target);
    }
    state = FilePaneTabState(
      tabs: tabs,
      activeId: target.id,
      previewTitles: previewTitles ?? state.previewTitles,
      previewSources: previewSources ?? state.previewSources,
    );
  }

  /// 确保至少有一个标签；空列表时补一张空白页。返回是否补过。
  ///
  /// 右栏的显示状态与标签集合是两份状态：关掉最后一个标签会收起整栏，
  /// 再次显示时必须补页，否则会出现"有栏无内容"。
  bool ensureTabPage() {
    if (state.tabs.isNotEmpty) {
      return false;
    }
    final id = _nextStartId();
    state = FilePaneTabState(
      tabs: <PanelTabRef>[PanelTabRef.start(id)],
      activeId: id,
      previewTitles: state.previewTitles,
      previewSources: state.previewSources,
    );
    return true;
  }

  String _nextStartId() {
    String id;
    do {
      id = 'start-${++_startSeq}';
    } while (state.tabs.any((tab) => tab.id == id));
    return id;
  }

  /// 切换项目：预览里的旧文件全部失效，标签一起关掉。
  ///
  /// 会话产物（`media:` 标签）也一起关：切换项目意味着离开当前会话上下文，
  /// 留着上一段会话的图片标签只会让人以为它还属于新项目。
  ///
  /// 正在看预览时回落到它左侧最近的非预览标签（没有就往右找）；
  /// 终端、浏览器与空白页与项目无关，标签与选中态都保持不变。
  void resetForProject() {
    if (!state.hasPreview) {
      return;
    }
    final order = state.tabs;
    final remaining = <PanelTabRef>[
      for (final tab in order)
        if (tab.kind != FilePaneTab.preview) tab,
    ];

    final activeIndex = order.indexWhere((tab) => tab.id == state.activeId);
    String? nextId;
    if (activeIndex >= 0 && order[activeIndex].kind != FilePaneTab.preview) {
      nextId = state.activeId;
    } else {
      for (var i = activeIndex - 1; i >= 0 && nextId == null; i--) {
        if (order[i].kind != FilePaneTab.preview) {
          nextId = order[i].id;
        }
      }
      for (var i = activeIndex + 1; i < order.length && nextId == null; i++) {
        if (order[i].kind != FilePaneTab.preview) {
          nextId = order[i].id;
        }
      }
      if (nextId == null && remaining.isNotEmpty) {
        nextId = remaining.first.id;
      }
    }

    state = FilePaneTabState(
      tabs: remaining,
      activeId: nextId,
      // 预览都关了，标题表与来源表跟着清空：留着只会指向一批不存在的标签。
      previewTitles: const <String, String>{},
      previewSources: const <String, PreviewSource>{},
    );
    // 只剩预览、一清就空：补一张空白页。切项目不是"关标签"，
    // 不该顺手把整栏藏起来（只有用户自己关掉最后一个标签才收栏）。
    ensureTabPage();
  }
}
