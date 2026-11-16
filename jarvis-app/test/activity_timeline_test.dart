import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/features/conversations/activity_timeline.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

ChatStep _step(
  String label, {
  bool ok = true,
  int elapsedMs = 12,
  bool running = false,
  String id = '',
}) {
  return ChatStep(
    id: id,
    tool: 'read_file',
    label: label,
    ok: ok,
    elapsedMs: elapsedMs,
    running: running,
  );
}

void main() {
  testWidgets('折叠时只显示一行摘要，展开后才列出步骤', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ActivityTimeline(
          steps: [_step('已读取 a.html'), _step('已写入 a.html')],
        ),
      ),
    );

    // 耗时由消息元信息那行负责，摘要不再重复。
    expect(find.text('执行了 2 个步骤'), findsOneWidget);
    expect(find.textContaining('用时'), findsNothing);
    expect(find.text('已读取 a.html'), findsNothing, reason: '默认必须折叠，否则流水会盖住回答');

    await tester.tap(find.text('执行了 2 个步骤'));
    await tester.pumpAndSettle();

    expect(find.text('已读取 a.html'), findsOneWidget);
    expect(find.text('已写入 a.html'), findsOneWidget);
  });

  testWidgets('流式中头部说明当前在做什么', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ActivityTimeline(
          steps: [_step('正在读取 a.html', running: true)],
          streaming: true,
        ),
      ),
    );

    // 有一条进度指示在转，用 pump 而不是 pumpAndSettle。
    expect(find.text('正在读取 a.html · 已执行 1 步'), findsOneWidget);
  });

  testWidgets('失败的一步用错误色，并给出耗时', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const ActivityTimeline(
          steps: [
            ChatStep(tool: 'write_file', label: '未能写入 a.html', ok: false, elapsedMs: 3),
          ],
        ),
      ),
    );

    await tester.tap(find.text('执行了 1 个步骤'));
    await tester.pumpAndSettle();

    final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline_rounded));
    final context = tester.element(find.byType(ActivityTimeline));
    expect(
      icon.color,
      Theme.of(context).colorScheme.error,
      reason: '失败必须与成功区分开，否则用户看不出哪步没成',
    );
    expect(find.text('3ms'), findsOneWidget);
  });

  testWidgets('没有步骤时什么都不渲染', (tester) async {
    await tester.pumpWidget(_wrap(const ActivityTimeline(steps: <ChatStep>[])));

    expect(find.byType(Text), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });
}
