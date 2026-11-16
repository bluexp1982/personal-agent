import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/tasks/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TaskView _task(String state) => TaskView(
  id: 'task_1',
  type: 'skill:code-task',
  state: state,
  updatedAt: DateTime.now().millisecondsSinceEpoch,
);

void main() {
  testWidgets('未结束的任务会轮询，全部终态后停止', (tester) async {
    var state = 'running';
    var loads = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(null),
          tasksProvider.overrideWith((ref, projectId) {
            loads += 1;
            return <TaskView>[_task(state)];
          }),
        ],
        child: const MaterialApp(
          home: TasksPage(projectId: 'w1', embedded: true),
        ),
      ),
    );
    await tester.pump();

    expect(loads, 1, reason: '首帧只加载一次');
    expect(find.textContaining('执行中'), findsOneWidget);

    // 2 秒一拍：未结束的任务必须能看到新状态。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(loads, greaterThan(1), reason: '执行中的任务应继续刷新');

    state = 'succeeded';
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.textContaining('已完成'), findsOneWidget);

    final settled = loads;
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(loads, settled, reason: '全部到终态后不该继续空转');
  });
}
