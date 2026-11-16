import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/suggestion_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

const TaskSuggestion _suggestion = TaskSuggestion(
  skill: 'trip-plan',
  reason: '你提到下周三去上海',
  input: <String, dynamic>{'city': '上海'},
);

void main() {
  testWidgets('展示技能名、理由，点击触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SuggestionCard(
          suggestion: _suggestion,
          state: null,
          onTap: () => taps += 1,
        ),
      ),
    );

    expect(find.text('派一件事：出行方案编排'), findsOneWidget);
    expect(find.text('你提到下周三去上海'), findsOneWidget);

    await tester.tap(find.text('派这件事'));
    expect(taps, 1);
  });

  testWidgets('创建中显示进度且不可点', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SuggestionCard(
          suggestion: _suggestion,
          state: 'creating',
          onTap: () => taps += 1,
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('派这件事'), findsNothing);
    await tester.tap(find.byType(FilledButton));
    expect(taps, 0);
  });

  testWidgets('已创建后按钮禁用，重复点击不重复建任务', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SuggestionCard(
          suggestion: _suggestion,
          state: 'created',
          onTap: () => taps += 1,
        ),
      ),
    );

    expect(find.text('已创建'), findsOneWidget);
    await tester.tap(find.text('已创建'));
    expect(taps, 0);
  });

  testWidgets('任务进行中显示实时状态，按钮改成查看任务', (tester) async {
    var taps = 0;
    String? opened;
    await tester.pumpWidget(
      _wrap(
        SuggestionCard(
          suggestion: _suggestion,
          state: null,
          task: const TaskView(
            id: 'task_1',
            type: 'skill:trip-plan',
            state: 'running',
          ),
          onTap: () => taps += 1,
          onOpenTask: (id) => opened = id,
        ),
      ),
    );

    expect(find.text('执行中'), findsOneWidget);
    expect(find.text('查看任务'), findsOneWidget);
    expect(find.text('派这件事'), findsNothing);

    await tester.tap(find.text('查看任务'));
    expect(opened, 'task_1');
    expect(taps, 0, reason: '已有任务时不该再弹创建流程');
  });

  testWidgets('任务已完成时显示已完成，仍然只打开详情', (tester) async {
    String? opened;
    await tester.pumpWidget(
      _wrap(
        SuggestionCard(
          suggestion: _suggestion,
          state: null,
          task: const TaskView(
            id: 'task_2',
            type: 'skill:trip-plan',
            state: 'succeeded',
          ),
          onTap: () {},
          onOpenTask: (id) => opened = id,
        ),
      ),
    );

    expect(find.text('已完成'), findsOneWidget);
    await tester.tap(find.text('查看任务'));
    expect(opened, 'task_2');
  });

  testWidgets('派发失败显示重试，点击可以再派一次', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SuggestionCard(
          suggestion: _suggestion,
          state: 'failed',
          onTap: () => taps += 1,
        ),
      ),
    );

    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(taps, 1);
  });

  test('未知技能直接显示原名', () {
    expect(skillLabel('trip-plan'), '出行方案编排');
    expect(skillLabel('bill-explain'), '账单解读');
    expect(skillLabel('unknown-skill'), 'unknown-skill');
  });
}
