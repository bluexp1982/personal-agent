import 'package:jarvis_app/src/core/design/app_tokens.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/window_chrome.dart';
import 'package:jarvis_app/src/core/project_providers.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:jarvis_app/src/features/conversations/conversations_page.dart';
import 'package:jarvis_app/src/features/shell/embedded_toolbar.dart';
import 'package:jarvis_app/src/features/shell/file_pane_state.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/narrow_tabs.dart';
import 'package:jarvis_app/src/features/shell/panel_page.dart';
import 'package:jarvis_app/src/features/shell/panel_start_view.dart';
import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:jarvis_app/src/features/shell/rail_section_icons.dart';
import 'package:jarvis_app/src/features/shell/rail_view_menu.dart';
import 'package:jarvis_app/src/features/shell/project_icon.dart';
import 'package:jarvis_app/src/features/shell/shell_dividers.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:jarvis_app/src/features/shell/shell_resize_handle.dart';
import 'package:jarvis_app/src/features/settings/settings_dialog.dart';
import 'package:jarvis_app/src/features/profile/profile_page.dart';
import 'package:jarvis_app/src/features/settings/settings_page.dart';
import 'package:jarvis_app/src/features/shell/window_fullscreen.dart';
import 'package:jarvis_app/src/features/shell/project_panel.dart';
import 'package:jarvis_app/src/features/tasks/tasks_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

/// 主界面骨架：模式切换 + （窄屏）项目列表 /（宽屏）侧栏导航树 + 右侧详情。
///
/// 不接真实服务：把 `apiClientProvider` 覆盖成 null，数据全走传入的固定值，
/// 测试只关心"两种宽度下都能正常排布"和"切换模式会换掉列表内容"。
Widget _harness({
  List<Project>? projects,
  List<ConversationSummary>? conversations,
  List<TaskView>? tasks,
  bool macWindowInset = false,
  bool windowFullScreen = false,
}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(null),
      if (windowFullScreen)
        windowFullScreenProvider.overrideWith(_FixedWindowFullScreen.new),
      if (projects != null)
        projectsProvider.overrideWith((ref) => projects),
      if (conversations != null)
        conversationsProvider.overrideWith((ref, id) => conversations),
      if (tasks != null) tasksProvider.overrideWith((ref, id) => tasks),
    ],
    child: MaterialApp(
      builder: macWindowInset
          ? (context, child) => HiddenWindowTitleBarInset(
              child: child ?? const SizedBox.shrink(),
            )
          : null,
      home: const HomeShell(session: _session),
    ),
  );
}

/// 固定「窗口已在系统全屏」：真控制器会去问原生通道，测试里问不到。
class _FixedWindowFullScreen extends WindowFullScreenController {
  @override
  bool build() => true;
}

/// 宽屏导航树的一份固定数据：一个项目 + 一条会话 + 一条任务。
List<Project> _railProjects() => const <Project>[
  Project(
    id: 'w1',
    name: 'hello-demo',
    mode: ProjectModes.work,
    path: '/tmp/hello-demo',
    conversationCount: 1,
    taskCount: 1,
  ),
];

List<ConversationSummary> _railConversations() => const <ConversationSummary>[
  ConversationSummary(id: 'c1', title: '聊聊周末', updatedAt: 0, projectId: 'w1'),
];

List<TaskView> _railTasks() => const <TaskView>[
  TaskView(
    id: 't1',
    state: 'succeeded',
    type: 'skill:bill-explain',
    skill: 'bill-explain',
  ),
];

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 栏头「…」这类图标按钮必须与标签栏同一套规格：命中区 24、图标 14。
///
/// 图标尺寸走 `IconButton.iconSize`（`IconTheme` 生效），`Icon.size` 是 null，
/// 所以要量渲染尺寸而不是读 widget 字段。
/// 侧栏项目行按项目名定位：项目页栏头也会显示同一个名字，必须限定在左栏里。
Finder _railProjectRow(String name) => find.descendant(
  of: find.byType(RailNavigator),
  matching: find.text(name),
);

/// 把鼠标挪到侧栏某一行上：行尾两枚按钮只在悬停时可见。
///
/// 不用 `pumpAndSettle`：调用方可能已经打开了一条会话，而会话页在无服务端时
/// 带着常转的进度环，settle 会一直等到超时。120ms 的淡入用定长 pump 足够。
Future<TestGesture> _hoverRailProject(WidgetTester tester, String name) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(_railProjectRow(name)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return gesture;
}

void _expectHeaderIconButton(
  WidgetTester tester,
  String tooltip, {
  Finder? within,
}) {
  final tooltipFinder = within == null
      ? find.byTooltip(tooltip)
      : find.descendant(of: within, matching: find.byTooltip(tooltip));
  expect(tooltipFinder, findsOneWidget);
  expect(
    tester.getSize(
      find.ancestor(of: tooltipFinder, matching: find.byType(IconButton)),
    ),
    const Size.square(kPaneHeaderButtonSize),
    reason: '$tooltip 的命中区应与栏头一致',
  );
  expect(
    tester.getSize(
      find.descendant(of: tooltipFinder, matching: find.byType(Icon)),
    ),
    const Size.square(kPaneHeaderIconSize),
    reason: '$tooltip 的图标应与栏头一致',
  );
}

void main() {
  testWidgets('手机宽度显示项目空状态，且不溢出', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 窄屏的底部导航是自绘的悬浮胶囊（`NarrowTabBar`），不是 Material 的
    // `NavigationBar`；左侧导航栏只在宽屏出现。
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
    expect(
      find.byKey(kBottomNavKey),
      findsOneWidget,
      reason: '窄屏四个一级页共用一条底部导航',
    );

    // 模式概念已移除：顶栏不再有 CODE / WORK 字样或切换入口。
    expect(find.text('CODE'), findsNothing);
    expect(find.text('WORK'), findsNothing);
    expect(find.text('SSH'), findsNothing);
    expect(
      find.byKey(kPanelEntryKey),
      findsOneWidget,
      reason: '窄屏靠顶栏的面板入口打开文件与终端',
    );
    expect(find.text('还没有项目'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '360dp 下不应出现 RenderFlex 溢出');
  });

  testWidgets('桌面宽度不溢出：侧栏 + 右侧空状态', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 宽屏左栏不再有标题行：以导航树本身作为"侧栏在"的锚点。
    expect(find.byType(RailNavigator), findsOneWidget);
    // 宽屏不再有项目卡片网格：右侧默认只是一句引导。
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
    expect(find.text('还没有项目'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏顶栏只剩标题与面板入口，入口贴住右边缘', (tester) async {
    // 678 正是"Flexible + Spacer"组合会把右上角那枚顶离右边的典型宽度。
    await _setSurface(tester, const Size(678, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text('Jarvis'), findsOneWidget);
    expect(find.text('CODE'), findsNothing, reason: '模式概念已移除');
    expect(find.text('WORK'), findsNothing, reason: '模式概念已移除');

    // 记忆 / 录音 / 画布 / 设置四枚已经撤掉：前三者进了「我的」，
    // 录音与设置由底部导航接管。
    for (final tooltip in <String>['记忆', '录音笔记', '无限画布', '设置']) {
      expect(find.byTooltip(tooltip), findsNothing, reason: '顶栏不该再有「$tooltip」');
    }

    // 顶栏右内边距是 8：面板入口的右边界必须落在距窗口右边 8dp 处。
    final panel = tester.getRect(find.byKey(kPanelEntryKey));
    expect(panel.right, closeTo(678 - 8, 1), reason: '面板入口应该右对齐');
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏侧栏按项目只列出会话', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        projects: _railProjects(),
        conversations: _railConversations(),
        tasks: _railTasks(),
      ),
    );
    await tester.pumpAndSettle();

    // 默认展开第一个项目，于是会话直接可见（不必先点一下）。
    expect(find.text('hello-demo'), findsOneWidget);
    expect(find.text('聊聊周末'), findsOneWidget);
    // 任务不进侧栏：数据给到了也不渲染，任务只在项目详情的 Tab 里看。
    expect(find.text('bill-explain'), findsNothing);
    // 项目行不再挂「N 会话 · N 任务」的计数副标题。
    expect(find.textContaining('会话 ·'), findsNothing);

    // 项目在侧栏内，空状态提示在右侧内容区。
    expect(
      tester.getTopLeft(find.text('hello-demo')).dx,
      lessThan(kShellRailWidth),
    );
    expect(
      tester.getCenter(find.byKey(kShellEmptyChatKey)).dx,
      greaterThan(kShellRailWidth),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽窄屏都不再出现模式标语', (tester) async {
    for (final width in <double>[1200, 360]) {
      await _setSurface(tester, Size(width, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      expect(find.textContaining('生活与办公'), findsNothing);
      expect(find.textContaining('编程项目'), findsNothing);
      expect(find.text('CODE'), findsNothing);
      expect(find.text('WORK'), findsNothing);
      expect(tester.takeException(), isNull, reason: '宽度 $width 不应溢出');
    }
  });

  testWidgets('拖动分隔条可以调宽侧栏', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final before = tester.getSize(find.byType(RailNavigator)).width;
    expect(before, closeTo(kShellRailWidth, 1));

    await tester.drag(find.byKey(kRailResizeHandleKey), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(RailNavigator)).width,
      closeTo(before + 60, 1),
      reason: '向右拖动 60dp，侧栏应该跟着变宽',
    );

    // 拖到下限以内还是正常收窄。
    await tester.drag(find.byKey(kRailResizeHandleKey), const Offset(-40, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(RailNavigator)).width,
      closeTo(before + 20, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('越界要蓄力满半秒才收起，收起后反拖能按原宽度拉回来', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeShell)),
    );
    expect(find.byType(RailNavigator), findsOneWidget);
    final before = container.read(railWidthProvider);

    // 一口气拖过下限：宽度冻结，不收起。用持续手势而不是 `tester.drag()`：
    // 后者几个微任务就结束，永远蓄不满半秒。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(kRailResizeHandleKey)),
    );
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();

    expect(find.byType(RailNavigator), findsOneWidget, reason: '刚越界不能立刻收起');
    expect(
      container.read(railWidthProvider),
      closeTo(before, 1),
      reason: '越界不写宽度：重新展开要回到用户拖出来的那个值',
    );

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(RailNavigator), findsOneWidget, reason: '半秒还不够');

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RailNavigator), findsNothing, reason: '蓄满半秒才收起');
    expect(
      find.byKey(kRailAccountMenuKey),
      findsNothing,
      reason: '收起后侧栏连同底部的账户入口一起让出空间',
    );
    // 收起后拖动条仍留在树上（零宽）：摘掉就 dispose，手势会断，反拖拉不回来。
    expect(tester.getSize(find.byKey(kRailResizeHandleKey)).width, 0);

    // 手还没松，往右拖回来：栏按原宽度恢复。
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(find.byType(RailNavigator), findsOneWidget, reason: '反拖超过死区就要把栏拉回来');
    expect(
      tester.getSize(find.byType(RailNavigator)).width,
      closeTo(before, 1),
      reason: '恢复的是收起前那个宽度',
    );

    // 恢复之后继续跟手：再往右拖 60dp，宽度继续增长。
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(
      tester.getSize(find.byType(RailNavigator)).width,
      closeTo(before + 60, 1),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('蓄力未满时松手，侧栏不收起', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(kRailResizeHandleKey)),
    );
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.byType(RailNavigator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('蓄力中把分隔条拖回下限以上，蓄力作废', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeShell)),
    );
    final before = container.read(railWidthProvider);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(kRailResizeHandleKey)),
    );
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 拖回下限以内：进度清零，从这里重新计时。
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byType(RailNavigator), findsOneWidget);
    expect(
      tester.getSize(find.byType(RailNavigator)).width,
      closeTo(before + 40, 1),
    );
    await gesture.up();
    expect(tester.takeException(), isNull);
  });

  testWidgets('三栏各有栏头：左栏按钮在左栏，右栏开关在中栏右上角', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 左栏：只有一行栏头（标题行已经删掉），按钮在栏内。
    final railToggle = tester.getRect(find.byKey(kRailToggleKey));
    expect(
      railToggle.bottom,
      lessThanOrEqualTo(kPaneHeaderHeight),
      reason: '左栏按钮应该在左栏栏头里',
    );
    expect(
      railToggle.right,
      lessThanOrEqualTo(kShellRailWidth),
      reason: '按钮不能越过左栏右边界',
    );
    // 栏头下方直接是两行动作，不再有标题文字。
    expect(find.text('Jarvis'), findsNothing);
    expect(
      tester.getRect(find.byKey(kRailNewConversationKey)).top,
      greaterThanOrEqualTo(kPaneHeaderHeight),
      reason: '动作行在栏头下面',
    );

    // 中栏：右栏开关贴在中栏右端（窗口右边），与左栏按钮不在同一条横栏上。
    final fileToggle = tester.getRect(find.byKey(kFilePaneToggleKey));
    expect(
      fileToggle.right,
      closeTo(1200 - 6, 1),
      reason: '右栏开关贴住窗口右边（空状态的中栏栏头）',
    );
    expect(
      fileToggle.top,
      lessThan(kPaneHeaderHeight),
      reason: '中栏栏头同样在顶部，但属于中栏',
    );

    // 设置收进左栏底部的账户菜单，不占栏头。
    expect(find.byTooltip('设置'), findsNothing);
    expect(
      tester.getRect(find.byKey(kRailAccountMenuKey)).top,
      greaterThan(kPaneHeaderHeight),
      reason: '账户入口固定在左栏底部',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏侧栏可以彻底收起，再从中栏展开', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byType(RailNavigator), findsOneWidget);

    await tester.tap(find.byTooltip('隐藏侧栏'));
    await tester.pumpAndSettle();

    expect(find.byType(RailNavigator), findsNothing);
    expect(
      find.byKey(kRailAccountMenuKey),
      findsNothing,
      reason: '动作行与账户入口都画在侧栏里，收起后随之消失',
    );
    // 归零而不是留一条 48dp 窄条：内容区应该拿到整窗宽度。
    // 拖动条仍挂在树上（零宽），那是为了"蓄力收起后还能反拖回来"，
    // 视觉与命中上都等于不存在。
    expect(tester.getSize(find.byKey(kRailResizeHandleKey)).width, 0);
    expect(
      tester.getCenter(find.byKey(kShellEmptyChatKey)).dx,
      closeTo(600, 1),
      reason: '侧栏零宽后内容区中心落在窗口正中',
    );
    expect(find.byTooltip('显示侧栏'), findsOneWidget);

    await tester.tap(find.byTooltip('显示侧栏'));
    await tester.pumpAndSettle();

    expect(find.byType(RailNavigator), findsOneWidget);
    expect(
      tester.getSize(find.byType(RailNavigator)).width,
      closeTo(kShellRailWidth, 1),
      reason: '展开后回到默认宽度',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏没有全宽标题栏，也没有侧栏开合按钮', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byKey(kRailToggleKey), findsNothing);
    expect(find.byTooltip('隐藏侧栏'), findsNothing);
    expect(find.byTooltip('显示侧栏'), findsNothing);
    expect(find.byKey(kFilePaneToggleKey), findsNothing, reason: '窄屏没有右侧栏入口');
    // 顶部仍是品牌标题行（只有 Agent 标签有），底部是可切换的一级页导航。
    expect(find.text('Jarvis'), findsOneWidget);
    expect(find.byKey(kBottomNavKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏点侧栏会话，右侧原地显示对话', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        projects: _railProjects(),
        conversations: _railConversations(),
        tasks: _railTasks(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('聊聊周末'));
    // 不接服务端时 ChatPage 会一直停在加载态（无限旋转的进度环），
    // 所以这里不能用 pumpAndSettle，只推两帧让点击后的重建落地。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ChatPage), findsOneWidget);
    // 内嵌形态不画自己的 AppBar 与返回箭头，右侧只留一条细标题行。
    expect(find.byType(AppBar), findsNothing);
    // 输入栏是圆角面板 + 控件行：占位文案仍在（quill 画在 `RichText` 里，
    // 不再是 `TextField.hintText`），发送按钮以 tooltip 表达语义。
    expect(
      tester
          .widgetList<RichText>(find.byType(RichText))
          .any((rich) => rich.text.toPlainText().contains('发送消息；@ 技能派任务')),
      isTrue,
      reason: '空输入时应有占位提示',
    );
    expect(find.byTooltip('发送'), findsOneWidget);

    // 宽屏下限宽居中：窗口 1200 时右侧内容区约 890，输入框只占其中一栏，
    // 左右都留出空白，而不是从侧栏一路铺到窗口右边。
    //
    // 量的是输入面板的外框而不是编辑器本身：编辑器换成富文本后不再是
    // `TextField`，但"面板限宽居中"这条约束没有变。
    final panel = tester.getTopLeft(find.byKey(kChatComposerPanelKey));
    expect(
      tester.getSize(find.byKey(kChatComposerPanelKey)).width,
      lessThanOrEqualTo(kChatColumnMaxWidth),
    );
    expect(
      panel.dx,
      greaterThan(kShellRailWidth + 40),
      reason: '输入栏左侧要与侧栏之间留出空白',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏会话页「关闭」回到所属项目页', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        projects: _railProjects(),
        conversations: _railConversations(),
        tasks: _railTasks(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('聊聊周末'));
    // 不接服务端时 ChatPage 停在加载态（进度环常转），因此不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byTooltip('会话操作'), findsOneWidget);
    _expectHeaderIconButton(tester, '会话操作');

    await tester.tap(find.byTooltip('会话操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('删除会话'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // 关闭只收起对话：右侧回到这个项目的「会话 / 任务」，会话本身还在列表里。
    expect(find.text('会话 1'), findsOneWidget);
    expect(find.text('任务 1'), findsOneWidget);
    expect(find.byTooltip('会话操作'), findsNothing);
  });

  testWidgets('宽屏项目行只切展开；「项目操作」→「打开项目」才进详情页', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        projects: _railProjects(),
        conversations: _railConversations(),
        tasks: _railTasks(),
      ),
    );
    await tester.pumpAndSettle();

    // 第一次点击：默认展开的项目被收起，中栏仍是空态——项目行只是导航展开器。
    await tester.tap(_railProjectRow('hello-demo'));
    await tester.pumpAndSettle();
    expect(find.text('聊聊周末'), findsNothing, reason: '单击收起会话列表');
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget, reason: '中栏不跟着跳页');

    // 再点一次展开回来，中栏依旧不动。
    await tester.tap(_railProjectRow('hello-demo'));
    await tester.pumpAndSettle();
    expect(find.text('聊聊周末'), findsOneWidget);
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);

    // 悬停后行尾浮出两枚按钮，项目操作菜单里没有「关闭」。
    await _hoverRailProject(tester, 'hello-demo');
    await tester.tap(find.byKey(railProjectActionsKey('w1')));
    await tester.pumpAndSettle();
    expect(find.text('打开项目'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.text('删除项目'), findsOneWidget);
    expect(find.text('关闭'), findsNothing, reason: '侧栏入口不再提供「关闭」');

    await tester.tap(find.text('打开项目'));
    await tester.pumpAndSettle();

    expect(find.text('会话 1'), findsOneWidget);
    expect(find.text('任务 1'), findsOneWidget);

    // 页头与聊天页共用紧凑栏头：只有名称 + 更多菜单，不再挂模式徽章。
    expect(find.text('CODE'), findsNothing);
    expect(
      find.text('/tmp/hello-demo'),
      findsNothing,
      reason: '路径不再铺在栏头，免得挤掉标题（复制路径仍在操作菜单里）',
    );
    final header = find.byType(EmbeddedToolbar);
    expect(
      find.descendant(of: header, matching: find.byTooltip('项目操作')),
      findsOneWidget,
      reason: '侧栏行尾也有一枚「项目操作」，这里只看栏头那颗',
    );
    _expectHeaderIconButton(tester, '项目操作', within: header);
    expect(
      tester.getSize(header.first).height,
      lessThanOrEqualTo(kPaneHeaderHeight),
      reason: '项目页头应该是紧凑栏头，而不是整块渐变大头图',
    );

    await tester.tap(
      find.descendant(of: header, matching: find.byTooltip('项目操作')),
    );
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    expect(find.text('删除项目'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget, reason: '栏头菜单仍保留「关闭」');
    expect(
      tester.getTopLeft(find.text('关闭')).dy,
      lessThan(tester.getTopLeft(find.text('重命名')).dy),
      reason: '「关闭」排在「重命名」上面',
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // 关闭只收起右侧：项目仍留在侧栏，随时能再打开。
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
    expect(_railProjectRow('hello-demo'), findsOneWidget);
    expect(find.text('会话 1'), findsNothing);
  });

  testWidgets('宽屏左栏栏头只放导航，不再有模式下拉', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 导航树在左栏里；标题行已经删掉，整栏不再出现那段文字。
    expect(
      tester.getTopLeft(find.byType(RailNavigator)).dx,
      lessThan(kShellRailWidth),
      reason: '宽屏时导航树应该在左侧栏，而不是内容区上方',
    );
    expect(find.text('Jarvis'), findsNothing, reason: '左栏标题行已删除');
    expect(find.text('CODE'), findsNothing);
    expect(find.text('WORK'), findsNothing);

    // 非 macOS 没有红绿灯行：导航（开合 → 后退 → 前进）贴左，右端不再有模式胶囊。
    final back = tester.getRect(find.byKey(kRailBackKey));
    final forward = tester.getRect(find.byKey(kRailForwardKey));
    final toggle = tester.getRect(find.byKey(kRailToggleKey));
    expect(back.left, greaterThanOrEqualTo(toggle.right), reason: '后退紧跟开合');
    expect(
      forward.left,
      greaterThanOrEqualTo(back.right),
      reason: '前进在后退右侧',
    );

    // 内容区整体搬到侧栏右侧。
    expect(
      tester.getCenter(find.byKey(kShellEmptyChatKey)).dx,
      greaterThan(kShellRailWidth),
    );
    expect(tester.takeException(), isNull, reason: '侧栏布局不应溢出');
  });

  testWidgets('搜索并入「项目」标题行：搜索 → 视图选项 → 新建项目', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byKey(kRailSearchKey), findsOneWidget);
    expect(find.byKey(kRailViewOptionsKey), findsOneWidget);
    expect(find.byKey(kRailAddProjectKey), findsOneWidget);

    final label = tester.getRect(find.text('项目'));
    final search = tester.getRect(find.byKey(kRailSearchKey));
    final view = tester.getRect(find.byKey(kRailViewOptionsKey));
    final add = tester.getRect(find.byKey(kRailAddProjectKey));

    // 三枚同处「项目」标题行，从左到右：搜索 → 视图选项 → 新建项目。
    expect(search.center.dy, closeTo(label.center.dy, 6), reason: '与标题同行');
    expect(search.left, greaterThan(label.right), reason: '搜索在标题右侧');
    expect(view.left, greaterThan(search.right), reason: '视图选项在搜索右边');
    expect(add.left, greaterThan(view.right), reason: '添加项目在视图选项右边');
    expect(
      add.right,
      closeTo(kShellRailWidth - kPaneEdgeInset, 1),
      reason: '整簇右对齐到侧栏内边距（贴分隔线那侧扣掉 8dp 栏缝）',
    );

    // 三枚图标都是 15（比行内图标小一档），「项目」标题 13。
    for (final key in <Key>[
      kRailSearchKey,
      kRailViewOptionsKey,
      kRailAddProjectKey,
    ]) {
      expect(
        tester.getSize(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(RailSectionGlyph),
          ),
        ),
        const Size(15, 15),
        reason: '$key 的图标尺寸',
      );
    }
    expect(
      tester.widget<Text>(find.text('项目')).style?.fontSize,
      AppFontSize.base,
      reason: '分组标题与列表行同档',
    );

    await tester.tap(find.byKey(kRailSearchKey));
    await tester.pumpAndSettle();
    expect(find.text('搜索即将支持'), findsOneWidget);

    // 窄屏没有侧栏，这一簇（搜索 / 视图选项 / 新建项目）只在左栏「项目」标题行里。
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    expect(find.byKey(kRailSearchKey), findsNothing);
    expect(find.byKey(kRailViewOptionsKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('会话行不挂图标，标题与项目标题左对齐', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        projects: _railProjects(),
        conversations: _railConversations(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.text('聊聊周末')).left,
      closeTo(tester.getRect(find.text('hello-demo')).left, 0.5),
      reason: '会话标题要与项目标题落在同一条左边线上',
    );
    expect(
      find.descendant(
        of: find.byType(RailNavigator),
        matching: find.byIcon(Icons.chat_bubble_outline),
      ),
      findsNothing,
      reason: '会话行不再挂气泡图标',
    );
    // 行尾时间还在：删图标不能让右侧信息一起消失（夹具里的 updatedAt 是 0，
    // 紧凑格式给的是占位破折号）。
    expect(
      find.descendant(of: find.byType(RailNavigator), matching: find.text('—')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('项目行图标三态：单击只切展开，「打开项目」才选中', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        projects: _railProjects(),
        conversations: _railConversations(),
      ),
    );
    await tester.pumpAndSettle();

    // 只看侧栏里的图标：右侧内容区也可能有文件夹图标。
    Finder folderInRail({required bool expanded, required bool selected}) =>
        find.descendant(
          of: find.byType(RailNavigator),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ProjectFolderIcon &&
                widget.expanded == expanded &&
                widget.selected == selected,
          ),
        );

    // 默认展开第一个项目，但还没进入它（图标是灰的）。
    expect(folderInRail(expanded: true, selected: false), findsOneWidget);
    expect(folderInRail(expanded: false, selected: false), findsNothing);
    expect(folderInRail(expanded: true, selected: true), findsNothing);

    // 点一下项目 = 只收起：图标换成收起态，仍是普通灰色。
    await tester.tap(_railProjectRow('hello-demo'));
    await tester.pumpAndSettle();
    expect(folderInRail(expanded: false, selected: false), findsOneWidget);
    expect(folderInRail(expanded: true, selected: false), findsNothing);
    expect(folderInRail(expanded: false, selected: true), findsNothing);

    // 再点一下展开，图标依然不转色。
    await tester.tap(_railProjectRow('hello-demo'));
    await tester.pumpAndSettle();
    expect(folderInRail(expanded: true, selected: false), findsOneWidget);

    // 从行尾「项目操作」进详情页之后，这一行的图标记成"当前所在项目"。
    await _hoverRailProject(tester, 'hello-demo');
    await tester.tap(find.byKey(railProjectActionsKey('w1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开项目'));
    await tester.pumpAndSettle();
    expect(folderInRail(expanded: true, selected: true), findsOneWidget);
    expect(folderInRail(expanded: true, selected: false), findsNothing);

    // 在这个项目里时再点行：收起会话列表，但中栏不变，图标仍是指路色。
    await tester.tap(_railProjectRow('hello-demo'));
    await tester.pumpAndSettle();
    expect(folderInRail(expanded: false, selected: true), findsOneWidget);
    expect(folderInRail(expanded: true, selected: true), findsNothing);
    expect(folderInRail(expanded: false, selected: false), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('会话进行中：项目行只有指路图标，不再叠一层选中底', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        projects: _railProjects(),
        conversations: _railConversations(),
      ),
    );
    await tester.pumpAndSettle();

    // 行底画在 `_RailRow` 的 `Container.decoration` 上，项目名最近的
    // `Container` 祖先就是那一层。
    Color? rowTint() {
      final container = tester.widget<Container>(
        find
            .ancestor(
              of: _railProjectRow('hello-demo'),
              matching: find.byType(Container),
            )
            .first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    // 空状态：项目行没有底色。
    expect(rowTint(), isNull);

    // 打开它名下的一条会话：会话行照旧有选中底，项目行不该跟着亮。
    await tester.tap(find.text('聊聊周末'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(rowTint(), isNull, reason: '会话进行中的项目行不再画选中底');
    expect(
      find.descendant(
        of: find.byType(RailNavigator),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ProjectFolderIcon &&
              widget.expanded &&
              widget.selected,
        ),
      ),
      findsOneWidget,
      reason: '蓝色文件夹仍要指出当前所在的项目',
    );

    // 进项目详情页：行底才是"这一页"的标记。
    await _hoverRailProject(tester, 'hello-demo');
    await tester.tap(find.byKey(railProjectActionsKey('w1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('打开项目'));
    await tester.pumpAndSettle();
    expect(rowTint(), isNotNull, reason: '项目详情页时项目行仍有选中底');

    expect(tester.takeException(), isNull);
  });

  testWidgets('视图选项是占位菜单：三组齐全，点了只换勾选', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    Finder row(String id) => find.byKey(Key('rail-view-item-$id'));
    Finder checkIn(String id) => find.descendant(
      of: row(id),
      matching: find.byIcon(Icons.check_rounded),
    );

    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();

    for (final title in <String>['分组方式', '排序方式', '筛选会话']) {
      expect(find.text(title), findsOneWidget, reason: '分组标题 $title');
    }
    for (final label in <String>[
      '按项目',
      '按项目树',
      '单列表',
      '手动排序',
      '最近更新',
      '隐藏已归档',
      '全部对话（显示已归档）',
      '仅显示已归档',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '菜单项 $label');
    }

    // 每组默认勾一个：按项目 / 最近更新 / 隐藏已归档。
    expect(checkIn('project'), findsOneWidget);
    expect(checkIn('recent'), findsOneWidget);
    expect(checkIn('hide-archived'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));

    // 占位期也是可点的：点一下只把勾选挪过去，不改变列表内容。
    await tester.tap(row('single-list'));
    await tester.pumpAndSettle();
    expect(row('single-list'), findsNothing, reason: '选中后菜单收起');

    await tester.tap(find.byKey(kRailViewOptionsKey));
    await tester.pumpAndSettle();
    expect(checkIn('single-list'), findsOneWidget);
    expect(checkIn('project'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口的面板入口是顶栏唯一的按钮，且不压到底部导航', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(kPanelEntryKey));
    final nav = tester.getRect(find.byKey(kBottomNavKey));

    expect(panel.bottom, lessThan(80), reason: '面板入口在顶栏里，不占下方内容');
    expect(panel.right, closeTo(360 - 8, 1), reason: '顶栏右内边距 8');
    expect(nav.top, greaterThan(panel.bottom), reason: '导航在内容之下，不挤顶栏');
    expect(tester.takeException(), isNull);
  });

  testWidgets('断点 700：699 还是顶部布局，700 切到侧栏', (tester) async {
    for (final width in <double>[699, 700]) {
      await _setSurface(tester, Size(width, 800));
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      expect(
        find.byType(RailNavigator),
        width >= kShellBreakpoint ? findsOneWidget : findsNothing,
        reason: '宽度 $width 的布局方向与断点不一致',
      );
      expect(tester.takeException(), isNull, reason: '宽度 $width 不应溢出');
    }
  });

  testWidgets('窄屏顶栏的面板入口以整页形式打开面板', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kPanelEntryKey));
    await tester.pumpAndSettle();

    expect(find.byType(PanelPage), findsOneWidget);
    expect(find.byKey(kPanelStartTerminalCardKey), findsOneWidget);
    // 整页形态没有"关闭右侧栏"，改为返回；栏内开合按钮也不该出现。
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byTooltip('关闭右侧栏'), findsNothing);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.byType(PanelPage), findsNothing);
    expect(find.text('还没有项目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏设置收在底部账户菜单里，栏头只放栏开关', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 底部只剩一行账户入口；设置不在明面上，也不会跑到栏头里。
    expect(find.byTooltip('设置'), findsNothing);
    expect(find.byKey(kFilePaneToggleKey), findsOneWidget);
    final account = tester.getRect(find.byKey(kRailAccountMenuKey));
    expect(
      account.top,
      greaterThan(kPaneHeaderHeight),
      reason: '账户入口在栏头下面',
    );

    await tester.tap(find.byKey(kRailAccountMenuKey));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    // 浮层向上弹：菜单条目在触发器上方。
    expect(
      tester.getTopLeft(find.text('设置')).dy,
      lessThan(account.top),
      reason: '底部菜单应向触发器上方展开',
    );

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    // 设置现在是浮层：断言浮层本身，不依赖某一栏是否刚好被访问过。
    expect(find.byKey(kSettingsDialogKey), findsOneWidget);
  });

  testWidgets('窄屏「我的」是一级标签，设置从它推入整页并可返回', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(narrowTabKey(NarrowTab.profile)));
    await tester.pumpAndSettle();

    // 「我的」自己是一级标签：底部导航在，页头没有返回。
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(find.byKey(kBottomNavKey), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('无限画布'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    // 顶栏品牌行只在 Agent 标签出现，「我的」用自己的页头。
    expect(find.text('Jarvis'), findsNothing);

    // 设置是「我的」的下级整页：推入后盖住底部导航，带返回钮。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('连接与设备'), findsOneWidget);
    expect(find.byKey(kBottomNavKey), findsNothing);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(find.byKey(kBottomNavKey), findsOneWidget);
  });

  testWidgets('macOS 隐藏标题栏：左栏让开红绿灯，中栏从顶端开始', (tester) async {
    // 平台覆盖必须在测试体内还原：框架在测试体结束时就会校验它。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurface(tester, const Size(1200, 800));
      await tester.pumpWidget(_harness(macWindowInset: true));
      await tester.pumpAndSettle();

      // 左栏只剩红绿灯这一行栏头，标题行已经删掉。
      final railToggle = tester.getRect(find.byKey(kRailToggleKey));
      expect(
        railToggle.top,
        lessThan(kMacWindowButtonsHeight),
        reason: '左栏按钮要和红绿灯在同一行',
      );
      expect(
        railToggle.left,
        greaterThanOrEqualTo(kMacWindowButtonsWidth),
        reason: '按钮不能压住红绿灯',
      );

      // 中栏开关与左栏按钮落在同一条水平线上。
      final fileToggle = tester.getRect(find.byKey(kFilePaneToggleKey));
      expect(
        fileToggle.center.dy,
        closeTo(railToggle.center.dy, 1),
        reason: '中栏开关与左栏按钮水平位置一致',
      );
      expect(
        railToggle.center.dy,
        closeTo(kPaneHeaderHeight / 2, 1),
        reason: '栏头按钮在三栏首行里垂直居中，与原生下移后的红绿灯同轴',
      );

      expect(
        tester.getRect(find.byKey(kRailNewConversationKey)).top,
        greaterThanOrEqualTo(kPaneHeaderHeight),
        reason: '栏头下面直接是两行动作，不再有标题行',
      );

      // 收起左栏：中栏贴到窗口左边，展开按钮必须落在红绿灯右侧，
      // 且与展开时的横坐标**完全一致**——两侧栏头各自的左内边距
      // （左栏 0、中栏 4）必须互相配平，否则同一枚按钮会横向跳几 dp。
      await tester.tap(find.byKey(kRailToggleKey));
      await tester.pumpAndSettle();
      final collapsedToggle = tester.getRect(find.byKey(kRailToggleKey));
      expect(
        collapsedToggle.left,
        closeTo(kMacWindowButtonsWidth, 0.5),
        reason: '中栏展开按钮要让开红绿灯',
      );
      expect(
        collapsedToggle.left,
        closeTo(railToggle.left, 0.5),
        reason: '展开 / 收起时开合按钮落在同一根竖线上，与红绿灯的间距不变',
      );

      // 窄屏没有栏头，顶部内容仍由 SafeArea 让开红绿灯。
      await _setSurface(tester, const Size(360, 800));
      await tester.pumpWidget(_harness(macWindowInset: true));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Jarvis')).dy,
        greaterThanOrEqualTo(kMacWindowButtonsHeight),
        reason: '窄屏顶部标题要让开红绿灯',
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('系统全屏没有红绿灯：左栏开合按钮回到左端，退出后还原', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurface(tester, const Size(1200, 800));
      await tester.pumpWidget(
        _harness(macWindowInset: true, windowFullScreen: true),
      );
      await tester.pumpAndSettle();

      final toggle = tester.getRect(find.byKey(kRailToggleKey));
      expect(
        toggle.left,
        closeTo(kPaneContentInset, 1),
        reason: '全屏没有红绿灯，按钮贴到内容左内边距，不再让出 78dp',
      );
      expect(
        tester.getRect(find.byKey(kRailNewConversationKey)).top,
        greaterThanOrEqualTo(kPaneHeaderHeight),
        reason: '标题行删掉后，栏头下面直接是动作行',
      );

      // 收起左栏：没有红绿灯时按钮同样落在 12 的内容线上，
      // 不能只剩中栏栏头自己那 4dp——那会让按钮在展开 / 收起之间横跳 8dp。
      await tester.tap(find.byKey(kRailToggleKey));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(kRailToggleKey)).left,
        closeTo(kPaneContentInset, 0.5),
        reason: '全屏收起左栏后，开合按钮仍落在内容线上',
      );
      expect(tester.takeException(), isNull);

      // 退出全屏：留白回来，按钮回到红绿灯右侧。
      // 先卸掉整棵树：ProviderScope 不允许在两次 pump 之间增删 override。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_harness(macWindowInset: true));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(kRailToggleKey)).left,
        greaterThanOrEqualTo(kMacWindowButtonsWidth),
        reason: '退出全屏后恢复原样，不能压住红绿灯',
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('中栏按钮打开右侧栏，面板里的按钮收起它，默认收起', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(projects: _railProjects()));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectPanel), findsNothing, reason: '默认不改变现有的两栏布局');

    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectPanel), findsOneWidget);
    expect(find.text('项目文件'), findsOneWidget);
    expect(find.byKey(kPanelStartTerminalCardKey), findsOneWidget);

    // 面板打开后，中栏那个按钮让位：同一屏只留一个开合入口。
    expect(
      find.byKey(kFilePaneToggleKey),
      findsNothing,
      reason: '面板打开时中栏按钮应当隐藏',
    );

    await tester.tap(find.byKey(kFilePaneHideKey));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectPanel), findsNothing);
    expect(
      find.byKey(kFilePaneToggleKey),
      findsOneWidget,
      reason: '面板收起后中栏入口回来，否则就再也打不开了',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('右侧栏拖过下限要蓄力才收起，收起后反拖能拉回来', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(projects: _railProjects()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(kFilePaneWidth, 1),
    );

    // 右栏贴右边：向左拖（dx 为负）才是变宽。
    await tester.drag(
      find.byKey(kFilePaneResizeHandleKey),
      const Offset(-60, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(kFilePaneWidth + 60, 1),
    );
    final before = kFilePaneWidth + 60;

    // 往回收窄到下限以下：先冻结，蓄力满了才收起（与左栏同一套手感）。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(kFilePaneResizeHandleKey)),
    );
    await gesture.moveBy(const Offset(400, 0));
    await tester.pump();
    expect(find.byType(ProjectPanel), findsOneWidget, reason: '刚越界不能立刻收起');

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(ProjectPanel), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProjectPanel), findsNothing, reason: '蓄满半秒才收起');
    // 收起后拖动条压成零宽留在树上，否则手势会断、反拖拉不回来。
    expect(tester.getSize(find.byKey(kFilePaneResizeHandleKey)).width, 0);

    // 手还没松，反向（向左）拖回来：面板按原宽度恢复。
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(
      find.byType(ProjectPanel),
      findsOneWidget,
      reason: '反拖超过死区就要把面板拉回来',
    );
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(before, 1),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('分隔处只剩一条线：线常驻在面板边界上，悬停换色且两端渐隐', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(projects: _railProjects()));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // 左栏 | 中栏：分隔线由拖动条提供，压在左栏与中栏的边界（命中区右边缘）。
    final railHandle = find.byKey(kRailResizeHandleKey);
    final railLine = find.descendant(
      of: railHandle,
      matching: find.byKey(kResizeHandleLineKey),
    );
    // 线的渐变：静止态整条同色，悬停态两端透明、中段实色。
    LinearGradient lineGradient(Finder line) {
      final decoration = tester.widget<AnimatedContainer>(line).decoration;
      return (decoration! as BoxDecoration).gradient! as LinearGradient;
    }

    expect(railLine, findsOneWidget);
    expect(tester.getSize(railLine).width, 1, reason: '线常驻 1px');
    expect(
      tester.getRect(railLine).right,
      closeTo(tester.getRect(railHandle).right, 0.1),
      reason: '线要压在面板边界上，不能落在 8dp 栏缝中央',
    );
    expect(lineGradient(railLine).begin, Alignment.topCenter);
    expect(lineGradient(railLine).end, Alignment.bottomCenter);
    expect(
      lineGradient(railLine).colors.toSet(),
      hasLength(1),
      reason: '静止态整条同色：分隔线在栏头栏尾也要读得出来，不做渐隐',
    );

    await mouse.moveTo(tester.getCenter(railHandle));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(railLine).width,
      1,
      reason: '悬停不加粗：只换颜色，线宽始终 1px',
    );
    expect(
      tester.getRect(railLine).right,
      closeTo(tester.getRect(railHandle).right, 0.1),
      reason: '换色不能挪位置，否则又变两条',
    );

    final hovered = lineGradient(railLine);
    expect(hovered.stops, <double>[0, 0.2, 0.8, 1]);
    expect(hovered.colors.first.a, 0, reason: '顶端渐隐');
    expect(hovered.colors.last.a, 0, reason: '底端渐隐');
    expect(
      hovered.colors[1].a,
      greaterThan(0),
      reason: '两端之间是实色：从上下两端往中间亮起来，而不是只亮正中一点',
    );
    expect(
      hovered.colors[1].a,
      lessThanOrEqualTo(0.5),
      reason: '提示性线条，压得比正文弱：再实就会像一道分色带',
    );

    // 中栏 | 右栏：同理，线贴在右栏左边界（命中区左边缘）。
    await mouse.moveTo(Offset.zero);
    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pumpAndSettle();

    final paneHandle = find.byKey(kFilePaneResizeHandleKey);
    final paneLine = find.descendant(
      of: paneHandle,
      matching: find.byKey(kResizeHandleLineKey),
    );
    expect(paneLine, findsOneWidget);
    expect(tester.getSize(paneLine).width, 1);
    expect(
      tester.getRect(paneLine).left,
      closeTo(tester.getRect(paneHandle).left, 0.1),
      reason: '线要压在右栏左边界上',
    );
    expect(lineGradient(paneLine).colors.toSet(), hasLength(1));

    await mouse.moveTo(tester.getCenter(paneHandle));
    await tester.pumpAndSettle();
    expect(tester.getSize(paneLine).width, 1);
    expect(
      tester.getRect(paneLine).left,
      closeTo(tester.getRect(paneHandle).left, 0.1),
    );
    // 右栏这条与左栏那条同一套实现：线宽、渐变方向与两端透明必须一致。
    expect(lineGradient(paneLine).begin, Alignment.topCenter);
    expect(lineGradient(paneLine).colors.first.a, 0);
    expect(lineGradient(paneLine).colors.last.a, 0);
    expect(lineGradient(paneLine).colors[1].a, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('横线由骨架层独占：起笔点就是竖线，栏自己不再画', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(projects: _railProjects()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(kShellDividerLayerKey),
      findsOneWidget,
      reason: '宽屏有一条骨架级横线层',
    );

    // 横线的起笔点必须与左栏那条竖线重合：差 8dp 就正好是之前那个缺口。
    final railHandle = find.byKey(kRailResizeHandleKey);
    final layout = tester.widget<ShellDividers>(find.byType(ShellDividers));
    expect(layout.centerLeft, closeTo(tester.getRect(railHandle).right, 0.1));
    expect(layout.footerVisible, isTrue, reason: '底部账户行上方那条线由骨架补到竖线上');

    // 画布必须以窗口左缘为原点：只包中栏的话 x=0 已经在中栏左边，
    // centerLeft 会被算两遍，两条横线整体右移一条栏宽。
    expect(tester.getRect(find.byKey(kShellDividerLayerKey)).left, 0);

    // 中栏栏头不能再自己画：同一条线画两遍会在栏缝处一深一浅。
    final toolbar = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(EmbeddedToolbar),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(toolbar.decoration, isNull, reason: '中栏栏头横线已交给骨架层');

    // 右栏标签栏同样让位，且它必须知道自己处在骨架层之下（否则会画出第二条）。
    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kShellDividerLayerKey), findsOneWidget, reason: '开右栏不加层');
    expect(
      ShellDividerScope.isActive(tester.element(find.byType(ProjectPanel))),
      isTrue,
      reason: '面板要认出"横线已经有人画了"',
    );

    // 左栏收起：竖线没了，横线改从窗口左缘起笔，底部那条也跟着消失。
    await tester.tap(find.byKey(kRailToggleKey));
    await tester.pumpAndSettle();
    final collapsed = tester.widget<ShellDividers>(find.byType(ShellDividers));
    expect(collapsed.centerLeft, 0);
    expect(collapsed.footerVisible, isFalse, reason: '没有「设置」那一格，也就没有那条线');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏不画骨架分隔线，栏头横线仍由栏自己画', (tester) async {
    await _setSurface(tester, const Size(680, 800));
    await tester.pumpWidget(_harness(projects: _railProjects()));
    await tester.pumpAndSettle();

    // 这一层始终在树上（宽窄切换不能让下面的 Element 换深度），只是不画。
    expect(find.byType(ShellDividers), findsOneWidget);
    expect(find.byKey(kShellDividerLayerKey), findsNothing);
    expect(
      ShellDividerScope.isActive(
        tester.element(find.byKey(kPanelEntryKey)),
      ),
      isFalse,
      reason: '窄屏没有骨架横线，栏内的横线仍要自己画',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板全屏吃掉中栏，左侧栏仍然在', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(projects: _railProjects()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();

    // 中栏让位，面板铺满「窗口 - 左栏 - 分隔条」，左栏与它的导航树都不动。
    expect(find.byKey(kShellEmptyChatKey), findsNothing);
    expect(find.byType(RailNavigator), findsOneWidget);
    expect(find.byKey(kRailAccountMenuKey), findsOneWidget);
    expect(find.byKey(kFilePaneResizeHandleKey), findsNothing);
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(1200 - kShellRailWidth - kRailHandleWidth, 1),
    );
    // 没有右栏拖动条时，分隔线仍由左栏拖动条提供（贴在它的远端）。
    expect(
      find.descendant(
        of: find.byKey(kRailResizeHandleKey),
        matching: find.byKey(kResizeHandleLineKey),
      ),
      findsOneWidget,
      reason: '全屏下左栏与面板之间也要有且只有这一条线',
    );
    expect(find.byTooltip('退出全屏'), findsOneWidget);

    await tester.tap(find.byKey(kFilePaneFullscreenKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
    expect(
      tester.getSize(find.byType(ProjectPanel)).width,
      closeTo(kFilePaneWidth, 1),
      reason: '退出全屏后回到用户拖出来的宽度',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窗口放不下面板时自动收起，不留死路', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(projects: _railProjects()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kFilePaneToggleKey));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectPanel), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeShell)),
    );

    // 900dp 放不下 320 的最小面板 + 380 的中栏：这时不能"状态是开、界面没有"。
    await _setSurface(tester, const Size(900, 800));
    await tester.pumpAndSettle();

    expect(find.byType(ProjectPanel), findsNothing);
    expect(
      container.read(filePaneVisibleProvider),
      isFalse,
      reason: '状态要跟着收起，否则中栏入口永远不会回来',
    );
    expect(find.byKey(kFilePaneToggleKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
