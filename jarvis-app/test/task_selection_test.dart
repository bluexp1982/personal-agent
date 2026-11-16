import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/ui/adaptive_card_list.dart';
import 'package:jarvis_app/src/features/tasks/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

TaskView _task({required String state}) {
  return TaskView(id: 'task_1', type: 'skill:code-task', state: state);
}

void main() {
  test('canDeleteTask 只放行终态', () {
    expect(canDeleteTask('succeeded'), isTrue);
    expect(canDeleteTask('failed'), isTrue);
    expect(canDeleteTask('canceled'), isTrue);

    for (final running in <String>[
      'queued',
      'running',
      'needs_input',
      'needs_approval',
    ]) {
      expect(canDeleteTask(running), isFalse, reason: running);
    }
  });

  testWidgets('执行中的任务在管理态不可勾选，并说明原因', (tester) async {
    var toggles = 0;

    await tester.pumpWidget(
      _wrap(
        TaskListTile(
          task: _task(state: 'running'),
          managing: true,
          selected: false,
          onToggle: () => toggles++,
          onOpen: () {},
        ),
      ),
    );

    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(checkbox.onChanged, isNull);
    expect(find.textContaining('先取消再删'), findsOneWidget);

    await tester.tap(find.byType(AdaptiveCardRow));
    expect(toggles, 0, reason: '不可删的行点击整行也不该被选中');
  });

  testWidgets('已结束任务可勾选并触发回调', (tester) async {
    var toggles = 0;

    await tester.pumpWidget(
      _wrap(
        TaskListTile(
          task: _task(state: 'succeeded'),
          managing: true,
          selected: false,
          onToggle: () => toggles++,
          onOpen: () {},
        ),
      ),
    );

    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(checkbox.onChanged, isNotNull);

    await tester.tap(find.byType(AdaptiveCardRow));
    expect(toggles, 1);
  });

  testWidgets('非管理态不显示复选框，点击进入详情', (tester) async {
    var opened = 0;

    await tester.pumpWidget(
      _wrap(
        TaskListTile(
          task: _task(state: 'failed'),
          managing: false,
          selected: false,
          onToggle: () {},
          onOpen: () => opened++,
        ),
      ),
    );

    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(find.byType(AdaptiveCardRow));
    expect(opened, 1);
  });
}
