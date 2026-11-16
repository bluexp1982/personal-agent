import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/conversations_page.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:jarvis_app/src/features/tasks/tasks_page.dart';
import 'package:jarvis_app/src/features/projects/project_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 项目详情页的头部只有一行：左侧 Tab、右侧工具动作，底部一条细线。
///
/// 不接真实服务：`apiClientProvider` 覆盖成 null，列表走传入的固定值。
Widget _harness({
  required Project project,
  List<ConversationSummary> conversations = const <ConversationSummary>[],
  List<TaskView> tasks = const <TaskView>[],
}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(null),
      conversationsProvider.overrideWith((ref, id) => conversations),
      tasksProvider.overrideWith((ref, id) => tasks),
    ],
    child: MaterialApp(home: ProjectDetailPage(project: project)),
  );
}

const Project _project = Project(
  id: 'w1',
  name: 'hello-demo',
  mode: ProjectModes.work,
  path: '/tmp/hello-demo',
  conversationCount: 0,
  taskCount: 1,
);

const List<TaskView> _tasks = <TaskView>[
  TaskView(
    id: 't1',
    state: 'succeeded',
    type: 'skill:bill-explain',
    skill: 'bill-explain',
  ),
];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 700,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 700);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Tab 与工具动作在同一行，原来的工具行不再存在', (tester) async {
    await _pump(tester, _harness(project: _project, tasks: _tasks));

    expect(tester.takeException(), isNull);

    // 任务 Tab 有内容，切过去右侧才有「管理」。
    await tester.tap(find.text('任务 1'));
    await tester.pumpAndSettle();

    // 合并行左侧是 Tab，右侧是工具动作，两者垂直中心对齐。
    final tabCenter = tester.getCenter(find.text('任务 1'));
    final manageCenter = tester.getCenter(find.byTooltip('管理'));
    expect((tabCenter.dy - manageCenter.dy).abs(), lessThan(2));

    // 旧工具行的标题（精确的「任务」二字）已经没有了，Tab 文案带计数。
    expect(find.text('任务'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    // 「管理」与「刷新」同一套栏头规格：命中区 24、图标 14。
    for (final tooltip in <String>['管理', '刷新']) {
      final button = find.byTooltip(tooltip);
      expect(
        tester.getSize(
          find.ancestor(of: button, matching: find.byType(IconButton)),
        ),
        const Size.square(kPaneHeaderButtonSize),
        reason: '$tooltip 的命中区应与栏头一致',
      );
      expect(
        tester.getSize(
          find.descendant(of: button, matching: find.byType(Icon)),
        ),
        const Size.square(kPaneHeaderIconSize),
        reason: '$tooltip 的图标应与栏头一致',
      );
    }

    // Tab 仍贴左侧排列（首个标签距左 16dp），右侧留给工具动作。
    expect(tester.getTopLeft(find.text('会话 0')).dx, lessThan(40));

    // 合并行与栏头同高（40dp，含 1dp 底线）。
    expect(
      tester.getSize(find.byType(TabBar)).height,
      kPaneHeaderHeight - kPaneHeaderBorderWidth,
    );
  });

  testWidgets('切到任务 Tab 后右侧换成任务页的动作', (tester) async {
    // 会话为空、任务有一条：切换前后「管理」按钮的有无可以直接区分两页。
    await _pump(tester, _harness(project: _project, tasks: _tasks));

    expect(find.byTooltip('管理'), findsNothing);

    await tester.tap(find.text('任务 1'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('管理'), findsOneWidget);
  });

  testWidgets('进入管理态后右侧变成全选 / 完成，底部删除条仍在', (tester) async {
    await _pump(tester, _harness(project: _project, tasks: _tasks));

    await tester.tap(find.text('任务 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('管理'));
    await tester.pumpAndSettle();

    expect(find.text('全选'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(find.byTooltip('管理'), findsNothing);

    // 退出管理态回到「管理 / 刷新」。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('管理'), findsOneWidget);
    expect(find.text('全选'), findsNothing);
  });

  testWidgets('窄中栏下合并行不溢出，Tab 仍可横向滚动', (tester) async {
    await _pump(
      tester,
      _harness(project: _project, tasks: _tasks),
      width: 200,
    );

    expect(tester.takeException(), isNull);

    await tester.tap(find.text('任务 1'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('管理'), findsOneWidget);
    expect(
      tester.getSize(find.byType(TabBar)).height,
      kPaneHeaderHeight - kPaneHeaderBorderWidth,
    );
  });
}
