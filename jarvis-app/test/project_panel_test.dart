import 'package:jarvis_app/src/core/browser/browser_controller.dart';
import 'package:jarvis_app/src/core/browser/browser_models.dart';
import 'package:jarvis_app/src/core/git_models.dart';
import 'package:jarvis_app/src/core/git_providers.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/ssh/ssh_controller.dart';
import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:jarvis_app/src/core/ssh/terminal_start_directory.dart';
import 'package:jarvis_app/src/core/ui/shell_icon_button.dart';
import 'package:jarvis_app/src/core/project_file_providers.dart';
import 'package:jarvis_app/src/features/browser/browser_pane.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/panel_fullscreen.dart';
import 'package:jarvis_app/src/features/shell/panel_start_view.dart';
import 'package:jarvis_app/src/features/shell/panel_tab_menu.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:jarvis_app/src/features/shell/project_file_pane.dart';
import 'package:jarvis_app/src/features/shell/project_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const Project _project = Project(
  id: 'ws_1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/hello-demo',
);

/// 未连接的终端控制器替身：`SshPage._bootstrap()` 会读钥匙串并探测隧道，
/// 测试环境两样都没有，不替换就会抛异常或卡住。
class _IdleSshController extends SshController {
  /// 关闭终端标签必须真的断开连接，测试直接数调用次数。
  int disconnects = 0;

  @override
  SshState build() => const SshState.initial();

  @override
  Future<SshSavedCredentials> loadSaved() async => const SshSavedCredentials();

  /// `_bootstrap()` 现在走一次性决策接口：不覆盖就会真去读会话与钥匙串。
  @override
  Future<SshAutoLoginPlan> loadAutoLoginPlan() async => const SshAutoLoginPlan(
    credentials: SshSavedCredentials(),
    autoLogin: false,
    canAutoLogin: false,
  );

  @override
  Future<void> probe() async {}

  /// 关标签走的是"放弃会话"那条路径（`discardSession`），不是状态栏的「断开」：
  /// 后者会把状态停在「已断开」，下次打开终端就看不到连接表单了。
  @override
  Future<void> discardSession() async {
    disconnects++;
  }
}

/// 数一数"关标签时有没有真的释放浏览器会话"。
///
/// 关标签走的是 provider 失效，释放发生在 `onDispose` 里，所以数销毁次数；
/// 同时数 build 次数——关标签不该让会话被重建（那会留下一个空壳 provider）。
class _BrowserDisposals {
  int builds = 0;
  int disposes = 0;
}

class _SpyBrowserController extends BrowserController {
  _SpyBrowserController(super.tabId, this.disposals);

  final _BrowserDisposals disposals;

  @override
  BrowserSessionState build() {
    disposals.builds++;
    ref.onDispose(() => disposals.disposes++);
    // 真实实现的保活与通道释放都在 super.build() 里，替身不能把它绕过去。
    return super.build();
  }
}

/// 固定选中项，免去在 widget 测试里驱动左侧导航树。
class _FixedTarget extends ShellTargetController {
  _FixedTarget(this.initial);

  final ShellTarget? initial;

  @override
  ShellTarget? build() => initial;
}

Widget _harness({
  ShellTarget? target = const ProjectTarget(_project),
  double width = 360,
  Map<String, ProjectListing> listings = const <String, ProjectListing>{},
  Map<String, FileContent> contents = const <String, FileContent>{},
  _BrowserDisposals? disposals,
}) {
  final tracker = disposals ?? _BrowserDisposals();
  return ProviderScope(
    overrides: [
      shellTargetProvider.overrideWith(() => _FixedTarget(target)),
      sshControllerProvider.overrideWith(_IdleSshController.new),
      // 浏览器面板只测标签与空态：真实 WebView 需要平台视图，widget 测试里起不来。
      browserSessionProvider.overrideWith2(
        (id) => _SpyBrowserController(id, tracker),
      ),
      projectListingProvider.overrideWith((ref, key) {
        return listings[key.path] ?? ProjectListing(path: key.path);
      }),
      projectFileContentProvider.overrideWith((ref, key) {
        return contents[key.path] ??
            const FileContent(path: '', size: 0, text: '');
      }),
      // Git 面板只测标签接线：状态给一份固定值，免得它去读一个不存在的后端。
      gitStatusProvider.overrideWith(
        (ref, projectId) =>
            const GitStatusReport(repo: true, detached: false, branch: 'main'),
      ),
      gitLogProvider.overrideWith((ref, key) => const GitCommitsPage()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(width: width, height: 700, child: ProjectPanel()),
      ),
    ),
  );
}

/// 文件树里的某个条目。
///
/// 预览标签的标题就是文件名，直接 `find.text('main.dart')` 会同时命中标签与树，
/// 必须限定在文件树里点。
Finder _treeEntry(String name) => find.descendant(
  of: find.byType(ProjectFilePane),
  matching: find.text(name),
);

Map<String, ProjectListing> _tree() {
  return <String, ProjectListing>{
    '': const ProjectListing(
      path: '/tmp/hello-demo',
      entries: <ProjectEntry>[
        ProjectEntry(name: 'src', path: '/tmp/hello-demo/src', kind: 'dir'),
        ProjectEntry(
          name: 'README.md',
          path: '/tmp/hello-demo/README.md',
          kind: 'file',
          size: 12,
        ),
      ],
    ),
    '/tmp/hello-demo/src': const ProjectListing(
      path: '/tmp/hello-demo/src',
      entries: <ProjectEntry>[
        ProjectEntry(
          name: 'main.dart',
          path: '/tmp/hello-demo/src/main.dart',
          kind: 'file',
          size: 30,
        ),
      ],
    ),
  };
}

/// 在某个标签上按下鼠标右键。菜单"按下即弹"，一次次要键的 tap 就够。
Future<void> _rightClick(WidgetTester tester, Key tabKey) async {
  await tester.tap(
    find.byKey(tabKey),
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

/// 点**当前这张**空白页上的功能卡片。
///
/// 按 Key 而不是按文案：卡片标题会与标签栏文案重名（「终端」既是卡片也是
/// 打开后那个标签），只靠文字定位会随"标签是否已经存在"忽多忽少。
/// 标签栏可以同时挂着多张空白页，它们各自渲染同一套卡片，
/// `hitTestable` 只留下真正显示并可命中的那一张，避免 tap 命中多处。
Future<void> _tapStartCard(WidgetTester tester, Key cardKey) async {
  await tester.tap(find.byKey(cardKey).hitTestable());
  await tester.pumpAndSettle();
}

/// 点标签栏以外的空白处收起菜单（左下角离标签与菜单都足够远）。
Future<void> _dismissMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 590));
  await tester.pumpAndSettle();
}

void main() {
  group('panelTabWidth', () {
    test('只有一个标签时封顶最大宽度，不铺满整条栏', () {
      expect(panelTabWidth(available: 500, count: 1), kPanelTabMaxWidth);
    });

    test('两个标签按可用宽度平分（不超过上限）', () {
      expect(panelTabWidth(available: 344, count: 2), closeTo(170, 0.01));
    });

    test('放不下时按实际宽度平分，不抬到最小值（否则必然溢出）', () {
      final width = panelTabWidth(available: 340, count: 4);
      expect(width, lessThan(kPanelTabMinWidth));
      expect(width * 4 + kPanelTabGap * 3, lessThanOrEqualTo(340.01));
    });
  });

  group('panelTabIndexAt', () {
    test('标签内取对应下标，缝里取更近的一侧', () {
      expect(panelTabIndexAt(dx: 10, tabWidth: 100, count: 3), 0);
      expect(panelTabIndexAt(dx: 99, tabWidth: 100, count: 3), 0);
      // 缝是 [100,104)：靠左归前一个，靠右归后一个。
      expect(panelTabIndexAt(dx: 101, tabWidth: 100, count: 3), 0);
      expect(panelTabIndexAt(dx: 103, tabWidth: 100, count: 3), 1);
      expect(panelTabIndexAt(dx: 106, tabWidth: 100, count: 3), 1);
    });

    test('超出最后一个标签返回 null（拖动区与工具按钮）', () {
      // 3 个标签总宽 = 100*3 + 4*2 = 308。
      expect(panelTabIndexAt(dx: 307, tabWidth: 100, count: 3), 2);
      expect(panelTabIndexAt(dx: 340, tabWidth: 100, count: 3), isNull);
      expect(panelTabIndexAt(dx: -1, tabWidth: 100, count: 3), isNull);
      expect(panelTabIndexAt(dx: 10, tabWidth: 0, count: 0), isNull);
    });
  });

  testWidgets('开始页列出面板能力，占位项标注即将支持', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('项目文件'), findsOneWidget);
    expect(find.byKey(kPanelStartTerminalCardKey), findsOneWidget);
    expect(find.text('浏览器'), findsOneWidget);
    expect(find.byKey(kPanelStartGitCardKey), findsOneWidget);
    expect(find.text('更多工具'), findsOneWidget);
    // 只剩「更多工具」还是占位：浏览器已经接上真实能力。
    expect(find.text('即将支持'), findsOneWidget);
    expect(find.textContaining('hello-demo'), findsOneWidget);
  });

  testWidgets('点「Git」卡片把当前空白页换成 Git 标签并显示分支', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await _tapStartCard(tester, kPanelStartGitCardKey);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    expect(container.read(filePaneTabProvider).active, FilePaneTab.git);
    expect(find.byKey(kPanelGitTabKey), findsOneWidget);
    expect(
      find.byKey(kPanelStartTabKey),
      findsNothing,
      reason: '空白页原位转换成 Git 标签',
    );
    expect(find.text('main'), findsOneWidget);
  });

  // 回归护栏：把 UA 换成"WKWebView 原味"之后，百度会返回 https→http 的降级空壳，
  // 再被 HSTS 升回 https，页面就死循环白屏。这一段少了就等于功能坏了。
  test('浏览器 UA 必须是 Safari 形态', () {
    expect(kSafariUserAgent, contains('AppleWebKit/605.1.15'));
    expect(kSafariUserAgent, contains('Version/'));
    expect(kSafariUserAgent, contains('Safari/605.1.15'));
  });

  testWidgets('点「浏览器」打开一个浏览器标签并展示空态', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('浏览器'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    final id = container.read(filePaneTabProvider).browserTabs.single;
    expect(find.byKey(panelBrowserTabKey(id)), findsOneWidget);
    expect(find.text('新标签页'), findsOneWidget, reason: '空白标签的标题');
    expect(find.text('输入 HTTP(S) 地址开始浏览'), findsOneWidget);
    expect(find.text('输入 HTTP(S) 地址'), findsOneWidget, reason: '地址框提示');
    expect(tester.takeException(), isNull);
  });

  testWidgets('每点一次「浏览器」都新开一个标签', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('浏览器'));
    await tester.pumpAndSettle();
    // 空白页已经被换成浏览器标签：点「+」再要一张新空白页，然后点第二次。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浏览器'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    final ids = container.read(filePaneTabProvider).browserTabs;
    expect(ids, hasLength(2), reason: '浏览器语义：每次点击都是新的一页');
    expect(
      container.read(filePaneTabProvider).tabs,
      hasLength(2),
      reason: '两次点击各自占用一张空白页，不会额外留下空标签',
    );
    expect(find.byKey(panelBrowserTabKey(ids[0])), findsOneWidget);
    expect(find.byKey(panelBrowserTabKey(ids[1])), findsOneWidget);
    expect(find.text('新标签页'), findsNWidgets(2), reason: '空白标签统一叫「新标签页」');
    expect(
      container.read(filePaneTabProvider).activeBrowserId,
      ids[1],
      reason: '新建的标签成为当前标签',
    );
  });

  testWidgets('关闭一个浏览器标签只释放它自己的会话', (tester) async {
    final disposals = _BrowserDisposals();
    await tester.pumpWidget(_harness(disposals: disposals));
    await tester.pumpAndSettle();

    await tester.tap(find.text('浏览器'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浏览器'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    final ids = container.read(filePaneTabProvider).browserTabs;

    await tester.tap(
      find.descendant(
        of: find.byKey(panelBrowserTabKey(ids[1])),
        matching: find.byTooltip('关闭浏览器标签'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(panelBrowserTabKey(ids[1])), findsNothing);
    expect(
      find.byKey(panelBrowserTabKey(ids[0])),
      findsOneWidget,
      reason: '另一个浏览器标签不受影响',
    );
    expect(disposals.disposes, 1, reason: '关标签必须释放桥接监听与静态服务');
    expect(disposals.builds, 2, reason: '两个标签各建一次会话；关闭不该重建出一份空壳');
    final state = container.read(filePaneTabProvider);
    expect(state.browserTabs, <String>[ids[0]]);
    expect(state.activeBrowserId, ids[0], reason: '回落到还活着的那一个');
  });

  testWidgets('「更多工具」仍是占位，点击只提示', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('更多工具'));
    await tester.pump();

    expect(find.text('「更多工具」即将支持'), findsOneWidget);
  });

  testWidgets('没有项目时「项目文件」禁用并说明原因', (tester) async {
    await tester.pumpWidget(_harness(target: null));
    await tester.pumpAndSettle();

    expect(find.text('项目文件'), findsOneWidget);
    // 限定在「项目文件」这张卡里断言：Git 面板同样要求先选项目，
    // 全页范围找会同时命中两张卡的副标题。
    expect(
      find.descendant(
        of: find.byKey(kPanelStartFilesCardKey),
        matching: find.text('先在左侧选择一个项目'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('项目文件'));
    await tester.pump();

    expect(find.text('先在左侧选择一个项目'), findsWidgets);
    expect(find.text('文件'), findsNothing);
  });

  testWidgets('点「终端」打开终端标签并展示连接表单', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kPanelStartTerminalCardKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kPanelTerminalTabKey), findsOneWidget);
    // 未连接时是连接表单：有密码框与「连接」按钮，说明真的走进了 SSH 能力，
    // 而不是弹一句"即将支持"。
    expect(find.text('连接服务器'), findsWidgets);
    expect(find.text('即将支持'), findsNothing);
  });

  testWidgets('点「终端」把当前项目目录登记成终端的起始目录', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    expect(container.read(terminalStartDirectoryProvider), isNull);

    await tester.tap(find.byKey(kPanelStartTerminalCardKey));
    await tester.pumpAndSettle();

    expect(
      container.read(terminalStartDirectoryProvider),
      _project.path,
      reason: '有项目时终端应落在项目目录，而不是远端用户家目录',
    );
  });

  testWidgets('没有项目时点「终端」清掉上一次的起始目录', (tester) async {
    await tester.pumpWidget(_harness(target: null));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    // 模拟"上一次带着项目开过终端"：不覆盖旧值就会 cd 到一条可能已不存在的路径。
    container
        .read(terminalStartDirectoryProvider.notifier)
        .request(_project.path);

    await tester.tap(find.byKey(kPanelStartTerminalCardKey));
    await tester.pumpAndSettle();

    expect(container.read(terminalStartDirectoryProvider), isNull);
  });

  testWidgets('关闭终端标签断开连接并回到相邻标签，但不改变全屏状态', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 先留一张空白页在终端左边：关掉终端要能回落到邻居，整栏不该跟着收起。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartTerminalCardKey);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    // 先把面板置于全屏：关标签只是"收起一页内容"，布局不该跟着变。
    container.read(panelFullscreenProvider.notifier).toggle();
    await tester.pumpAndSettle();
    expect(container.read(panelFullscreenProvider), isTrue);

    await tester.tap(find.byTooltip('关闭终端标签'));
    await tester.pumpAndSettle();

    expect(find.byKey(kPanelTerminalTabKey), findsNothing);
    expect(
      (container.read(
        sshControllerProvider.notifier,
      ) as _IdleSshController).disconnects,
      1,
      reason: '关标签等于放弃这台 shell，必须断开连接',
    );
    expect(
      container.read(filePaneTabProvider).active,
      FilePaneTab.start,
      reason: '关掉终端后回到左边的空白页',
    );
    expect(
      container.read(panelFullscreenProvider),
      isTrue,
      reason: '关标签不该改变面板的全屏状态',
    );
  });

  testWidgets('关掉最后一个标签会收起整栏，再显示时自动补一张空白页', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    container.read(filePaneVisibleProvider.notifier).show();
    await tester.pumpAndSettle();

    await _tapStartCard(tester, kPanelStartTerminalCardKey);
    await tester.tap(find.byTooltip('关闭终端标签'));
    await tester.pumpAndSettle();

    expect(
      container.read(filePaneTabProvider).isEmpty,
      isTrue,
      reason: '最后一个标签被关掉后标签列表为空',
    );
    expect(
      container.read(filePaneVisibleProvider),
      isFalse,
      reason: '没有标签时右栏自动收起，不留下一条空栏',
    );

    container.read(filePaneVisibleProvider.notifier).show();
    await tester.pumpAndSettle();

    final state = container.read(filePaneTabProvider);
    expect(state.tabs, hasLength(1), reason: '重新打开时自动补一张空白页');
    expect(state.active, FilePaneTab.start);
    expect(
      find.byKey(panelTabKey(state.tabs.single)),
      findsOneWidget,
      reason: '补出来的空白页要在标签栏里出现',
    );
  });

  testWidgets('标签少时封顶 180，多时等分且不溢出', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byKey(kPanelStartTabKey)).width,
      closeTo(kPanelTabMaxWidth, 1),
      reason: '只有一个标签时不铺满整条栏，留出可拖动窗口的空白',
    );

    // 每次「+」都新开一张空白页，选功能时把**当前这张**换掉：
    // 于是左边那张空白页留下来，凑成"开始 / 文件 / 终端"三个标签。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartFilesCardKey);
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartTerminalCardKey);

    // 开始 / 文件 / 终端 三个标签等宽平分。
    final widths = <double>[
      for (final key in <Key>[
        kPanelStartTabKey,
        kPanelFilesTabKey,
        kPanelTerminalTabKey,
      ])
        tester.getRect(find.byKey(key)).width,
    ];
    expect(widths[1], closeTo(widths[0], 0.5), reason: '三个标签应当等宽');
    expect(widths[2], closeTo(widths[0], 0.5));
    // 栏头左右内边距与两个工具按钮都已从可用宽度里扣掉：400 宽面板三分后约
    // 86.7dp——比两张标签时少的那一档正是「更多」按钮占的宽度。这个宽度仍放得下
    // 图标 + 三个字，再窄就该靠省略号兜底了。
    expect(
      widths[0],
      greaterThan(84),
      reason: '400 宽的面板里每个标签还要放得下图标 + 名字（三张时「更多」也占一份）',
    );
    expect(
      tester.getRect(find.byKey(kPanelTerminalTabKey)).right,
      lessThanOrEqualTo(400),
      reason: '平分后必须还在栏内，不能溢出',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('首行高度由标签加留白推导，标签上下各留同样一份间距', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();

    // 常量自身先自洽：改了标签高度或留白却忘记对齐栏高，这里先红。
    expect(
      kPaneHeaderHeight,
      closeTo(kPanelTabHeight + 2 * kPaneHeaderVerticalPadding, 0.01),
      reason: '首行高度必须是"标签 + 上下留白"，否则标签间距会被吃掉',
    );
    expect(
      kPaneHeaderButtonSize,
      lessThanOrEqualTo(kPanelTabHeight),
      reason: '栏内按钮高于标签时，加了纵向留白的那条 Row 会被撑破',
    );

    final panel = tester.getRect(find.byType(ProjectPanel));
    final tab = tester.getRect(find.byKey(kPanelStartTabKey));
    expect(tab.height, closeTo(kPanelTabHeight, 0.5));
    expect(
      tab.top - panel.top,
      closeTo(kPaneHeaderVerticalPadding, 0.5),
      reason: '标签上沿到面板顶部的距离就是上留白',
    );
    expect(
      panel.top + kPaneHeaderHeight - tab.bottom,
      closeTo(kPaneHeaderVerticalPadding, 0.5),
      reason: '标签下沿到首行底部的距离与上留白相等',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件标签也能关闭，关到最后一个就把右栏收起', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    container.read(filePaneVisibleProvider.notifier).show();
    await tester.pumpAndSettle();

    await _tapStartCard(tester, kPanelStartFilesCardKey);
    expect(find.byKey(kPanelFilesTabKey), findsOneWidget);
    expect(
      container.read(filePaneTabProvider).active,
      FilePaneTab.files,
      reason: '选功能 = 当前这张空白页被换成文件标签，不再额外开一个',
    );
    expect(
      find.byKey(kPanelStartTabKey),
      findsNothing,
      reason: '空白页被原位换掉，不会留下一张空标签',
    );

    await tester.tap(find.byTooltip('关闭文件标签'));
    await tester.pumpAndSettle();

    expect(find.byKey(kPanelFilesTabKey), findsNothing);
    expect(container.read(filePaneTabProvider).isEmpty, isTrue);
    expect(
      container.read(filePaneVisibleProvider),
      isFalse,
      reason: '没有标签了，右栏自动收起',
    );
  });

  testWidgets('关闭叉贴在标签右边缘，不跟在文字后面', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();

    final tab = tester.getRect(find.byKey(kPanelFilesTabKey));
    final close = tester.getRect(
      find.descendant(
        of: find.byKey(kPanelFilesTabKey),
        matching: find.byIcon(Icons.close),
      ),
    );

    expect(tab.right - close.right, lessThan(10), reason: '叉号要贴住标签右边缘');
    expect(
      close.left,
      greaterThan(tab.left + tab.width / 2),
      reason: '叉号在右半边，而不是紧跟在文字后面',
    );
  });

  testWidgets('关闭叉的悬停底是正方形，不随标签高度拉长', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();

    final closeButton = find.byTooltip('关闭文件标签');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(closeButton));
    await tester.pumpAndSettle();

    // 悬停底的形状就是按钮自身的尺寸：宽高必须一致，否则会被标签内边距
    // 或行高拉成竖条。
    final buttonFinder = find.ancestor(
      of: closeButton,
      matching: find.byType(IconButton),
    );
    expect(tester.getSize(buttonFinder), Size.square(kPanelTabCloseSize));

    // 圆角与栏头那套「24 见方 → 8」同比例：槽位缩到 16，圆角跟着到 5.33。
    final shape =
        tester
                .widget<IconButton>(buttonFinder)
                .style
                ?.shape
                ?.resolve(<WidgetState>{})
            as RoundedRectangleBorder;
    expect(
      shape.borderRadius.resolve(TextDirection.ltr).topLeft.x,
      closeTo(
        kShellIconButtonRadius * kPanelTabCloseSize / kPaneHeaderButtonSize,
        0.01,
      ),
    );
  });

  testWidgets('当前标签常显关闭叉，其它标签悬停才出现', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartTerminalCardKey);

    double closeOpacity(Key tabKey) => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(tabKey),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    expect(closeOpacity(kPanelTerminalTabKey), 1, reason: '当前标签的关闭叉常显');
    expect(closeOpacity(kPanelFilesTabKey), 0, reason: '非当前标签默认不显示');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(kPanelFilesTabKey)));
    await tester.pumpAndSettle();

    expect(closeOpacity(kPanelFilesTabKey), 1, reason: '悬停后关闭叉出现');
  });

  testWidgets('面板缩到最小宽度时终端表单仍不溢出', (tester) async {
    // 320 是右栏拖动下限：连接表单要能在这个宽度里排下来，
    // 否则用户一拉窄面板，终端就成了唯一不能用的标签。
    await tester.pumpWidget(_harness(width: kFilePaneMinWidth));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kPanelStartTerminalCardKey));
    await tester.pumpAndSettle();

    expect(find.text('连接服务器'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到别的标签不会关掉终端', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kPanelStartTerminalCardKey));
    await tester.pumpAndSettle();

    // 点「+」新开一张空白页（切走但不关终端）。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();

    expect(
      find.byKey(kPanelTerminalTabKey),
      findsOneWidget,
      reason: '终端只是"没在看"，不该被顺手关掉',
    );

    await tester.tap(find.byKey(kPanelTerminalTabKey));
    await tester.pumpAndSettle();
    expect(find.text('连接服务器'), findsWidgets);
  });

  testWidgets('项目文件：展开目录、预览文件、切回文件标签', (tester) async {
    final contents = <String, FileContent>{
      '/tmp/hello-demo/src/main.dart': const FileContent(
        path: '/tmp/hello-demo/src/main.dart',
        size: 30,
        text: 'void main() {\n  print("hi");\n}',
      ),
    };

    await tester.pumpWidget(_harness(listings: _tree(), contents: contents));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();

    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('src'), findsOneWidget);

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('main.dart'), findsOneWidget);

    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();

    expect(find.text('void main() {'), findsOneWidget);
    expect(find.text('  print("hi");'), findsOneWidget);

    // 预览页头的关闭键与标签栏那批按钮同一套规格：24 命中区 / 14 图标。
    final previewClose = find.byTooltip('关闭预览');
    expect(previewClose, findsOneWidget);
    expect(
      tester.getSize(
        find.ancestor(of: previewClose, matching: find.byType(IconButton)),
      ),
      const Size.square(kPaneHeaderButtonSize),
    );
    expect(
      tester.getSize(
        find.descendant(of: previewClose, matching: find.byType(Icon)),
      ),
      const Size.square(kPaneHeaderIconSize),
      reason: '图标尺寸取自 IconTheme（IconButton.iconSize），量渲染尺寸',
    );

    // 切回文件标签，树还在。
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget);

    // 再点预览标签回到内容，然后关闭预览回落到文件树。
    // 标签栏在上方、文件树在下方：同名的两处文本取第一个（标签）。
    await tester.tap(find.text('main.dart').first);
    await tester.pumpAndSettle();
    expect(find.text('void main() {'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭预览标签'));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('void main() {'), findsNothing);
    expect(find.byTooltip('关闭预览标签'), findsNothing, reason: '关闭后预览标签也应消失');
  });

  testWidgets('两个文件各开一个标签，重复打开只切回已有标签', (tester) async {
    final contents = <String, FileContent>{
      '/tmp/hello-demo/README.md': const FileContent(
        path: '/tmp/hello-demo/README.md',
        size: 12,
        text: '# hello-demo',
      ),
      '/tmp/hello-demo/src/main.dart': const FileContent(
        path: '/tmp/hello-demo/src/main.dart',
        size: 30,
        text: 'void main() {}',
      ),
    };

    await tester.pumpWidget(_harness(listings: _tree(), contents: contents));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('README.md'));
    await tester.pumpAndSettle();

    // 回到文件树再打开第二个文件。
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('src'));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('main.dart'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    expect(
      container.read(filePaneTabProvider).previews.length,
      2,
      reason: '每个文件一个标签',
    );
    expect(
      find.byKey(panelPreviewTabKey('/tmp/hello-demo/README.md')),
      findsOneWidget,
    );
    expect(
      find.byKey(panelPreviewTabKey('/tmp/hello-demo/src/main.dart')),
      findsOneWidget,
    );

    // 再次点同一个文件：只切焦点，不新增标签。
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('README.md'));
    await tester.pumpAndSettle();

    final state = container.read(filePaneTabProvider);
    expect(state.previews.length, 2, reason: '同一个文件不该重复开标签');
    expect(state.activePreviewPath, '/tmp/hello-demo/README.md');
    expect(find.text('# hello-demo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭当前预览标签会回到前一个文件标签', (tester) async {
    final contents = <String, FileContent>{
      '/tmp/hello-demo/README.md': const FileContent(
        path: '/tmp/hello-demo/README.md',
        size: 12,
        text: '# hello-demo',
      ),
      '/tmp/hello-demo/src/main.dart': const FileContent(
        path: '/tmp/hello-demo/src/main.dart',
        size: 30,
        text: 'void main() {}',
      ),
    };

    await tester.pumpWidget(_harness(listings: _tree(), contents: contents));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('README.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('src'));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('main.dart'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(panelPreviewTabKey('/tmp/hello-demo/src/main.dart')),
        matching: find.byTooltip('关闭预览标签'),
      ),
    );
    await tester.pumpAndSettle();

    final state = container.read(filePaneTabProvider);
    expect(state.previews.length, 1);
    expect(
      state.activePreviewPath,
      '/tmp/hello-demo/README.md',
      reason: '左邻优先：回到前一个文件标签',
    );
    expect(find.text('# hello-demo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板工具条只有一个隐藏入口：点它把显隐状态置为 false', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    container.read(filePaneVisibleProvider.notifier).show();
    await tester.pump();
    expect(container.read(filePaneVisibleProvider), isTrue);

    // 原来的 ✕ 已经并进这个按钮：不存在两个"关掉面板"的入口。
    expect(find.byTooltip('关闭右侧栏'), findsNothing);
    expect(find.byKey(kFilePaneHideKey), findsOneWidget);

    await tester.tap(find.byKey(kFilePaneHideKey));
    await tester.pump();

    expect(container.read(filePaneVisibleProvider), isFalse);
  });

  testWidgets('工具条的全屏按钮切换面板全屏，并换成退出全屏', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );

    expect(container.read(panelFullscreenProvider), isFalse);
    expect(find.byTooltip('全屏'), findsOneWidget);

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();

    expect(container.read(panelFullscreenProvider), isTrue);
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    expect(find.byTooltip('全屏'), findsNothing);

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();

    expect(container.read(panelFullscreenProvider), isFalse);
  });

  testWidgets('整页形态只有返回，没有全屏与隐藏', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellTargetProvider.overrideWith(() => _FixedTarget(null)),
          sshControllerProvider.overrideWith(_IdleSshController.new),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ProjectPanel(standalone: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byKey(kFilePaneFullscreenKey), findsNothing);
    expect(find.byKey(kFilePaneHideKey), findsNothing);
  });

  testWidgets('整页形态：返回在最左、新建标签在最右，360 宽不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellTargetProvider.overrideWith(() => _FixedTarget(null)),
          sshControllerProvider.overrideWith(_IdleSshController.new),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ProjectPanel(standalone: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final back = tester.getRect(find.byTooltip('返回'));
    final add = tester.getRect(find.byKey(kPanelNewTabKey));
    final tab = tester.getRect(
      find.byKey(panelTabKey(const PanelTabRef.start(kInitialPanelTabId))),
    );

    expect(
      back.right,
      lessThanOrEqualTo(tab.left),
      reason: '「返回」要排在第一个标签之前，落在最左',
    );
    expect(
      add.left,
      greaterThanOrEqualTo(tab.right),
      reason: '「+」要在所有标签之后，落在最右',
    );
    expect(tester.takeException(), isNull, reason: '360 宽下标签条不能溢出');
  });

  testWidgets('切换项目会关掉预览并收起目录', (tester) async {
    final contents = <String, FileContent>{
      '/tmp/hello-demo/src/main.dart': const FileContent(
        path: '/tmp/hello-demo/src/main.dart',
        size: 10,
        text: 'preview',
      ),
    };

    await tester.pumpWidget(
      _harness(
        listings: _tree(),
        contents: contents,
        target: const ProjectTarget(_project),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    expect(find.text('preview'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    container
        .read(shellTargetProvider.notifier)
        .select(
          const ProjectTarget(
            Project(
              id: 'ws_2',
              name: 'other',
              mode: ProjectModes.work,
              path: '/tmp/other',
            ),
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('preview'), findsNothing, reason: '预览属于上一个项目');
    expect(container.read(filePaneExpandedProvider), isEmpty);
  });

  group('closeTabs', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    /// 铺一条完整标签栏：开始 → 文件 → 终端 → a.md → b.md，停在 b.md 上。
    ///
    /// 每次打开都追加到末尾：插入顺序就是标签栏里的顺序。
    void seed() {
      final tabs = container.read(filePaneTabProvider.notifier);
      tabs.openFiles();
      tabs.openTerminal();
      tabs.openPreview(path: '/a.md', title: 'a.md');
      tabs.openPreview(path: '/b.md', title: 'b.md');
    }

    FilePaneTabState tabState() => container.read(filePaneTabProvider);

    test('标签按插入顺序排列', () {
      seed();
      expect(tabState().tabs, <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        const PanelTabRef.files(),
        const PanelTabRef.terminal(),
        const PanelTabRef.preview('/a.md'),
        const PanelTabRef.preview('/b.md'),
      ]);
    });

    test('空白页被选中的功能原位替换，位置不变', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      final first = tabs.openNewTabPage();
      final second = tabs.openNewTabPage();
      expect(tabState().tabs, hasLength(3), reason: '每个 + 都新开一张空白页');

      tabs.openPreview(path: '/a.md', title: 'a.md', intoTabId: second);

      expect(tabState().tabs, <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        PanelTabRef.start(first),
        const PanelTabRef.preview('/a.md'),
      ], reason: '第二张空白页原地变成预览，第一张留在原位');
      expect(tabState().active, FilePaneTab.preview);
    });

    test('Git 是单例标签：重复打开只切焦点，不堆出第二份', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      tabs.openGit();
      tabs.openFiles();
      tabs.openGit();

      expect(tabState().tabs, <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        const PanelTabRef.git(),
        const PanelTabRef.files(),
      ]);
      expect(tabState().active, FilePaneTab.git);
      expect(tabState().gitOpen, isTrue);

      tabs.closeGit();
      expect(tabState().gitOpen, isFalse);
    });

    test('单例功能已存在时切到已有标签并关掉空白页', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      tabs.openFiles();
      final blank = tabs.openNewTabPage();

      tabs.openFiles(intoTabId: blank);

      expect(tabState().tabs, <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        const PanelTabRef.files(),
      ], reason: '不新增第二个文件标签，也不留下那张空白页');
      expect(tabState().active, FilePaneTab.files);
    });

    test('关闭其他：只留右键的那个标签', () {
      seed();
      const anchor = PanelTabRef.preview('/a.md');
      expect(tabState().otherTabs(anchor), <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        const PanelTabRef.files(),
        const PanelTabRef.terminal(),
        const PanelTabRef.preview('/b.md'),
      ], reason: '空白页也能被关掉，不再有豁免');

      container
          .read(filePaneTabProvider.notifier)
          .closeTabs(tabState().otherTabs(anchor));

      final next = tabState();
      expect(next.tabs, <PanelTabRef>[anchor]);
      expect(next.activePreviewPath, '/a.md', reason: '活动标签 b.md 被关掉后回落到左邻');
      expect(next.previewTitles, <String, String>{
        '/a.md': 'a.md',
      }, reason: '关掉的预览不该把标题留在表里');
    });

    test('关闭左侧：锚点左边全关（含空白页）', () {
      seed();
      const anchor = PanelTabRef.preview('/b.md');
      expect(tabState().tabsBefore(anchor), <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        const PanelTabRef.files(),
        const PanelTabRef.terminal(),
        const PanelTabRef.preview('/a.md'),
      ]);

      container
          .read(filePaneTabProvider.notifier)
          .closeTabs(tabState().tabsBefore(anchor));

      final next = tabState();
      expect(next.tabs, <PanelTabRef>[anchor]);
      expect(next.activePreviewPath, '/b.md', reason: '锚点本身还开着，焦点不动');
      expect(next.filesOpen, isFalse);
      expect(next.terminalOpen, isFalse);
    });

    test('关闭右侧：锚点是文件标签时，终端与预览一起消失', () {
      seed();
      const anchor = PanelTabRef.files();
      container
          .read(filePaneTabProvider.notifier)
          .closeTabs(tabState().tabsAfter(anchor));

      final next = tabState();
      expect(next.tabs, <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        anchor,
      ]);
      expect(next.previews, isEmpty);
      expect(next.active, FilePaneTab.files, reason: '活动预览被关掉后回落到最近存活的左侧标签');
    });

    test('空白页也能单独关掉，关到最后一个就是空列表', () {
      // 初始只有一张空白页。
      container
          .read(filePaneTabProvider.notifier)
          .closeStartTab(kInitialPanelTabId);

      expect(tabState().isEmpty, isTrue);
      expect(tabState().activeTab, isNull);
      expect(tabState().active, isNull, reason: '空列表没有活动标签');
    });

    test('空列表时 ensureTabPage 补一张空白页', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      tabs.closeStartTab(kInitialPanelTabId);

      expect(tabs.ensureTabPage(), isTrue);
      expect(tabState().tabs, hasLength(1));
      expect(tabState().active, FilePaneTab.start);
      expect(tabs.ensureTabPage(), isFalse, reason: '已经有标签时不再补页');
    });

    test('浏览器按打开顺序插在终端之后、预览之前', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      tabs.openTerminal();
      final id = tabs.openNewBrowser();
      tabs.openPreview(path: '/a.md', title: 'a.md');

      expect(tabState().tabs, <PanelTabRef>[
        const PanelTabRef.start(kInitialPanelTabId),
        const PanelTabRef.terminal(),
        PanelTabRef.browser(id),
        const PanelTabRef.preview('/a.md'),
      ]);
    });

    test('每次点击浏览器都新开一个标签，点已有标签只切换', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      final first = tabs.openNewBrowser();
      final second = tabs.openNewBrowser();

      expect(tabState().browserTabs, <String>[
        first,
        second,
      ], reason: '不复用旧标签：点第二下要的是另一页');
      expect(tabState().activeBrowserId, second);

      tabs.activateBrowser(first);
      expect(tabState().activeBrowserId, first);
      expect(tabState().browserTabs, hasLength(2), reason: '切换不新增标签');
    });

    test('切换项目不关浏览器标签', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      final id = tabs.openNewBrowser();
      tabs.openPreview(path: '/a.md', title: 'a.md');

      tabs.resetForProject();

      final next = tabState();
      expect(next.previews, isEmpty, reason: '预览属于上一个项目');
      expect(next.browserTabs, <String>[id], reason: '浏览器地址由用户输入，与项目无关');
      expect(next.active, FilePaneTab.browser, reason: '预览被关掉后回到左侧最近的浏览器标签');
    });

    test('切换项目把标签清空时补一张空白页，不把整栏藏掉', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      // 只留一张预览：切项目后一张标签都不剩。
      tabs.closeStartTab(kInitialPanelTabId);
      tabs.openPreview(path: '/a.md', title: 'a.md');

      tabs.resetForProject();

      final next = tabState();
      expect(next.tabs, hasLength(1), reason: '切项目不是"关标签"，不该让右栏消失');
      expect(next.active, FilePaneTab.start);
      expect(next.previews, isEmpty);
    });

    test('批量关闭后浏览器标签一起清掉', () {
      final tabs = container.read(filePaneTabProvider.notifier);
      tabs.openFiles();
      final id = tabs.openNewBrowser();

      container
          .read(filePaneTabProvider.notifier)
          .closeTabs(tabState().otherTabs(const PanelTabRef.files()));

      final next = tabState();
      expect(next.browserTabs, isEmpty, reason: '关掉的是 $id 这个标签');
      expect(next.activeBrowserId, isNull);
      expect(next.filesOpen, isTrue);
      expect(next.active, FilePaneTab.files);
    });
  });

  testWidgets('右键标签弹出关闭菜单，空白页的「关闭」也可用', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();

    await _rightClick(tester, kPanelFilesTabKey);
    expect(find.byKey(kPanelTabMenuCloseKey), findsOneWidget);
    expect(find.byKey(kPanelTabMenuCloseOthersKey), findsOneWidget);
    expect(find.byKey(kPanelTabMenuCloseLeftKey), findsOneWidget);
    expect(find.byKey(kPanelTabMenuCloseRightKey), findsOneWidget);
    await _dismissMenu(tester);
    expect(
      find.byKey(kPanelTabMenuCloseKey),
      findsNothing,
      reason: '点击外部应收起菜单',
    );

    // 新开一张空白页：关掉它只影响它自己，文件标签原地不动。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    final blank = container.read(filePaneTabProvider).tabs.last;

    await _rightClick(tester, panelTabKey(blank));
    final closeItem = tester.widget<MenuItemButton>(
      find.byKey(kPanelTabMenuCloseKey),
    );
    expect(closeItem.onPressed, isNotNull, reason: '空白页（原来的「开始」）也能关掉');

    await tester.tap(find.byKey(kPanelTabMenuCloseKey));
    await tester.pumpAndSettle();
    expect(
      find.byKey(panelTabKey(blank)),
      findsNothing,
      reason: '点「关闭」应当真的关掉这张空白页',
    );
    expect(find.byKey(kPanelFilesTabKey), findsOneWidget);
  });

  testWidgets('标签栏的右键菜单只有一个锚点，「更多」按标签数另算一个', (tester) async {
    await tester.pumpWidget(_harness(width: 520));
    await tester.pumpAndSettle();

    // 一张标签：既没有「更多」按钮，也不该多出第二个锚点。
    expect(find.byKey(kPanelMoreMenuKey), findsNothing);
    expect(find.byType(MenuAnchor), findsOneWidget);

    // 两张：仍然不到显示门槛。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kPanelMoreMenuKey), findsNothing);
    expect(find.byType(MenuAnchor), findsOneWidget);

    // 三张：「更多」出现，因此多一个锚点；右键菜单本身仍只按命中标签现算，
    // 不会按标签数摊成 N 个。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kPanelMoreMenuKey), findsOneWidget);
    expect(find.byType(MenuAnchor), findsNWidgets(2));

    await _rightClick(tester, kPanelStartTabKey);
    expect(find.byKey(kPanelTabMenuCloseKey), findsOneWidget);
    await _dismissMenu(tester);
  });

  testWidgets('「更多」在「+」左侧，菜单列出全部标签并能直达', (tester) async {
    await tester.pumpWidget(_harness(width: 520));
    await tester.pumpAndSettle();

    // 连点两次「+」：三张空白页，够到「更多」的显示门槛。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    final tabs = container.read(filePaneTabProvider).tabs;
    expect(tabs, hasLength(3));

    final more = find.byKey(kPanelMoreMenuKey);
    expect(
      tester.getRect(more).right,
      lessThanOrEqualTo(tester.getRect(find.byKey(kPanelNewTabKey)).left),
      reason: '「更多」贴在「+」左侧',
    );

    await tester.tap(more);
    await tester.pumpAndSettle();

    // 每一张标签都在菜单里，底部一条分割线之后是两项批量关闭。
    for (final tab in tabs) {
      expect(find.byKey(panelMoreTabKey(tab.id)), findsOneWidget);
    }
    expect(find.byType(Divider), findsOneWidget, reason: '标签清单与批量关闭之间要有一条分割线');
    expect(find.byKey(kPanelTabMoreCloseOthersKey), findsOneWidget);
    expect(find.byKey(kPanelTabMoreCloseAllKey), findsOneWidget);

    await tester.tap(find.byKey(panelMoreTabKey(tabs.first.id)));
    await tester.pumpAndSettle();

    expect(container.read(filePaneTabProvider).activeId, tabs.first.id);
    expect(
      find.byKey(panelMoreTabKey(tabs.first.id)),
      findsNothing,
      reason: '选完一项菜单自己收起',
    );
  });

  testWidgets('「更多」的「关闭其他标签页」只留当前标签', (tester) async {
    await tester.pumpWidget(_harness(width: 520));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    final current = container.read(filePaneTabProvider).tabs.last;

    await tester.tap(find.byKey(kPanelMoreMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelTabMoreCloseOthersKey));
    await tester.pumpAndSettle();

    final next = container.read(filePaneTabProvider);
    expect(next.tabs.map((tab) => tab.id), <String>[
      current.id,
    ], reason: '除当前标签外的都被关掉');
    expect(next.activeId, current.id);
    expect(
      find.byKey(kPanelMoreMenuKey),
      findsNothing,
      reason: '只剩一张标签时「更多」自己消失',
    );
  });

  testWidgets('「更多」的「关闭全部标签页」清空标签、收起右栏并断开终端', (tester) async {
    await tester.pumpWidget(_harness(width: 520));
    await tester.pumpAndSettle();

    // 凑三张：开始 / 文件 / 终端（当前是终端）。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartFilesCardKey);
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartTerminalCardKey);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    // 让"收起右栏"成为一次可观测的变化：先把它显式打开。
    container.read(filePaneVisibleProvider.notifier).show();
    await tester.pumpAndSettle();
    expect(container.read(filePaneVisibleProvider), isTrue);

    await tester.tap(find.byKey(kPanelMoreMenuKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelTabMoreCloseAllKey));
    await tester.pumpAndSettle();

    expect(container.read(filePaneTabProvider).isEmpty, isTrue);
    expect(
      (container.read(
        sshControllerProvider.notifier,
      ) as _IdleSshController).disconnects,
      1,
      reason: '批量关闭也要放弃终端会话，而且只断一次',
    );
    expect(
      container.read(filePaneVisibleProvider),
      isFalse,
      reason: '没有标签时右栏自动收起',
    );
    expect(
      find.byKey(kPanelMoreMenuKey),
      findsNothing,
      reason: '标签没了，「更多」也跟着消失',
    );
  });

  testWidgets('右键哪个标签就按哪个标签出菜单', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();
    // 先点「+」留下左边的空白页，再把它右边那张换成文件标签。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartFilesCardKey);

    await _rightClick(tester, kPanelFilesTabKey);

    final close = tester.widget<MenuItemButton>(
      find.byKey(kPanelTabMenuCloseKey),
    );
    expect(close.onPressed, isNotNull, reason: '文件标签可以被关闭');
    expect(find.text('关闭左侧标签页'), findsOneWidget);
    await _dismissMenu(tester);
  });

  testWidgets('右键标签右侧的拖动区不弹标签菜单', (tester) async {
    await tester.pumpWidget(_harness(width: 520));
    await tester.pumpAndSettle();

    // 只有一个「开始」标签（宽 180），400 早已落在拖动区。
    await tester.tapAt(
      const Offset(400, 20),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(kPanelTabMenuCloseKey), findsNothing);
  });

  testWidgets('标签之间画分隔线，当前标签两侧不画，栏两端也不画', (tester) async {
    await tester.pumpWidget(_harness(width: 520));
    await tester.pumpAndSettle();

    // 只有「开始」一个标签：没有相邻标签，也就没有分隔线。
    expect(find.byKey(panelTabDividerKey(1)), findsNothing);

    // 每次「+」都新开一张空白页，选功能时只换掉当前那一张。
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartFilesCardKey);
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartTerminalCardKey);

    // 开始 / 文件 / 终端：当前是终端，紧贴它左侧那根不画，
    // 第 1 根照画，第 3 根（最后一个标签之后）不存在。
    expect(find.byKey(panelTabDividerKey(1)), findsOneWidget);
    expect(find.byKey(panelTabDividerKey(2)), findsNothing);
    expect(find.byKey(panelTabDividerKey(3)), findsNothing);

    // 线落在两个标签之间，而不是贴在栏的一端。
    final start = tester.getRect(find.byKey(kPanelStartTabKey));
    final files = tester.getRect(find.byKey(kPanelFilesTabKey));
    final divider = tester.getRect(find.byKey(panelTabDividerKey(1)));
    expect(divider.left, greaterThanOrEqualTo(start.right - 0.5));
    expect(divider.right, lessThanOrEqualTo(files.left + 0.5));
    expect(divider.height, closeTo(kPanelTabDividerHeight, 0.5));

    // 切到中间那张：左右两侧都贴着当前标签，一根都不画。
    await tester.tap(find.byKey(kPanelFilesTabKey));
    await tester.pumpAndSettle();
    expect(find.byKey(panelTabDividerKey(1)), findsNothing);
    expect(find.byKey(panelTabDividerKey(2)), findsNothing);

    // 切到第一张：只有右侧那根不画，另一根（文件与终端之间）回来。
    await tester.tap(find.byKey(kPanelStartTabKey));
    await tester.pumpAndSettle();
    expect(find.byKey(panelTabDividerKey(1)), findsNothing);
    expect(find.byKey(panelTabDividerKey(2)), findsOneWidget);
  });

  testWidgets('「+」在最后一个标签之后，点它打开一张空白新标签页', (tester) async {
    await tester.pumpWidget(_harness(width: 400));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );

    expect(find.byTooltip('新标签页'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(kPanelStartTabKey),
        matching: find.text(kPanelBlankTabLabel),
      ),
      findsOneWidget,
      reason: '空白页的标签名是「新标签页」，不再叫「开始」',
    );
    expect(find.text('开始'), findsNothing);
    expect(
      tester.getRect(find.byKey(kPanelNewTabKey)).left,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(kPanelStartTabKey)).right - 0.5,
      ),
      reason: '「+」紧跟在最后一个标签之后',
    );

    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();

    final state = container.read(filePaneTabProvider);
    expect(state.tabs, hasLength(2), reason: '每个 + 都新开一张空白页');
    expect(state.active, FilePaneTab.start);
    expect(find.byKey(panelTabKey(state.tabs.last)), findsOneWidget);
    expect(
      find.text('项目文件').hitTestable(),
      findsOneWidget,
      reason: '新标签页就是原来的开始页，直接列出功能入口',
    );
  });

  testWidgets('右键「+」按钮不弹标签菜单', (tester) async {
    await tester.pumpWidget(_harness(width: 520));
    await tester.pumpAndSettle();

    await tester.tapAt(
      tester.getCenter(find.byKey(kPanelNewTabKey)),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(kPanelTabMenuCloseKey), findsNothing);
  });

  testWidgets('右键「关闭右侧标签页」批量关标签，终端随之断开', (tester) async {
    final contents = <String, FileContent>{
      '/tmp/hello-demo/README.md': const FileContent(
        path: '/tmp/hello-demo/README.md',
        size: 12,
        text: '# hello-demo',
      ),
    };
    await tester.pumpWidget(
      _harness(listings: _tree(), contents: contents, width: 520),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kPanelNewTabKey));
    await tester.pumpAndSettle();
    await _tapStartCard(tester, kPanelStartTerminalCardKey);
    // 回文件树开一个预览，让「文件」右侧同时有终端与预览两个标签。
    await tester.tap(find.byKey(kPanelFilesTabKey));
    await tester.pumpAndSettle();
    await tester.tap(_treeEntry('README.md'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProjectPanel)),
    );
    expect(container.read(filePaneTabProvider).previews, hasLength(1));

    await _rightClick(tester, kPanelFilesTabKey);
    await tester.tap(find.byKey(kPanelTabMenuCloseRightKey));
    await tester.pumpAndSettle();

    final state = container.read(filePaneTabProvider);
    expect(state.terminalOpen, isFalse, reason: '终端在文件标签右侧');
    expect(state.previews, isEmpty);
    expect(state.filesOpen, isTrue);
    expect(state.active, FilePaneTab.files, reason: '关掉的预览回落到最近存活的左侧标签');
    expect(
      (container.read(
        sshControllerProvider.notifier,
      ) as _IdleSshController).disconnects,
      1,
      reason: '批量关掉终端也必须断开 shell，不能留在后台',
    );
    expect(find.byKey(kPanelTerminalTabKey), findsNothing);
    expect(find.byKey(kPanelTabMenuCloseKey), findsNothing, reason: '执行后菜单收起');
  });
}
