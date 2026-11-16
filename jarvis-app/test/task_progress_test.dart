import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/tasks/task_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 过程摘要：从 `plan[].output` 到任务详情页的「执行过程」区块。
///
/// 这一层最容易退化的两点：模型把空串当成有内容（于是出现空块），
/// 以及轮询重建把用户展开的步骤收回去。两条都在这里守住。

Map<String, dynamic> _taskJson({
  String state = 'running',
  List<Map<String, dynamic>> plan = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> artifacts = const <Map<String, dynamic>>[],
}) {
  return <String, dynamic>{
    'id': 'task_1',
    'conversation_id': 'conv_1',
    'type': 'skill:code-task',
    'skill': 'code-task',
    'state': state,
    'retry_count': 0,
    'created_at': 1,
    'updated_at': 2,
    'plan': plan,
    'artifacts': artifacts,
  };
}

Map<String, dynamic> _artifact(String id, String kind) {
  return <String, dynamic>{
    'id': id,
    'task_id': 'task_1',
    'kind': kind,
    'size': 10,
    'mime': 'text/plain',
    'created_at': 1,
  };
}

Widget _harness(Map<String, dynamic> body) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          // 这一页有 1.5s 轮询：用固定响应避免测试里出现随机时序。
          httpClient: MockClient(
            (http.Request request) async => http.Response(
              jsonEncode(body),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            ),
          ),
        ),
      ),
    ],
    child: const MaterialApp(
      home: TaskDetailPage(taskId: 'task_1', embedded: true),
    ),
  );
}

void main() {
  group('PlanStepView 解析', () {
    test('解析过程摘要与生成时间', () {
      final step = PlanStepView.fromJson(<String, dynamic>{
        'seq': 1,
        'name': '执行编码',
        'state': 'running',
        'output': '工具：Bash（只读）git status',
        'updated_at': 1700000000000,
      });

      expect(step.hasOutput, isTrue);
      expect(step.output, contains('Bash'));
      expect(step.updatedAt, 1700000000000);
    });

    test('缺字段、空串与非字符串都按"没有过程"处理', () {
      final missing = PlanStepView.fromJson(<String, dynamic>{
        'seq': 0,
        'name': '准备',
        'state': 'pending',
      });
      expect(missing.hasOutput, isFalse);
      expect(missing.updatedAt, isNull);

      final blank = PlanStepView.fromJson(<String, dynamic>{
        'seq': 0,
        'name': '准备',
        'state': 'pending',
        'output': '   ',
        'updated_at': 1,
      });
      expect(blank.output, isNull, reason: '空白摘要不该渲染成一个空块');

      final wrongType = PlanStepView.fromJson(<String, dynamic>{
        'seq': 0,
        'name': '准备',
        'state': 'pending',
        'output': 42,
      });
      expect(wrongType.output, isNull);
    });
  });

  test('产物种类映射成中文', () {
    expect(artifactKindLabel('run_log'), '运行日志');
    expect(artifactKindLabel('change_summary'), '改动摘要');
    expect(artifactKindLabel('diff'), '改动补丁');
    expect(artifactKindLabel('whatever'), 'whatever', reason: '未知种类原样显示');
  });

  testWidgets('执行中的步骤默认展开过程摘要', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      _harness(
        _taskJson(
          plan: <Map<String, dynamic>>[
            <String, dynamic>{
              'seq': 0,
              'name': '准备隔离项目',
              'state': 'done',
              'output': '工作树就绪：分支 agent/task_1',
              'updated_at': now,
            },
            <String, dynamic>{
              'seq': 1,
              'name': '执行编码',
              'state': 'running',
              'output': '工具：Bash（只读）git status\n完成：clean',
              'updated_at': now,
            },
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('执行过程'), findsOneWidget);
    // 只有正在跑的那一步展开：已完成的步骤保持折叠，避免整页被日志占满。
    final visible = tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    );
    expect(visible.length, 1);
    expect(visible.first.data, contains('git status'));
    // 两个步骤都带 updatedAt：标题行各自显示自己的更新时间。
    expect(find.textContaining('最后更新'), findsWidgets);

    // 手动展开已完成那一步。
    await tester.tap(find.text('准备隔离项目'));
    await tester.pump();
    final expanded = tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    );
    expect(expanded.length, 2);
    expect(
      expanded.map((widget) => widget.data).join(),
      contains('工作树就绪'),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('没有过程摘要时不出现空块，只显示步骤状态', (tester) async {
    await tester.pumpWidget(
      _harness(
        _taskJson(
          plan: <Map<String, dynamic>>[
            <String, dynamic>{
              'seq': 0,
              'name': '准备隔离项目',
              'state': 'running',
            },
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SelectableText), findsNothing, reason: '不能渲染空的过程块');
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('准备隔离项目'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('产物按"运行日志 / 改动摘要 / 补丁"排序并使用中文标题', (tester) async {
    await tester.pumpWidget(
      _harness(
        _taskJson(
          state: 'succeeded',
          plan: <Map<String, dynamic>>[
            <String, dynamic>{
              'seq': 0,
              'name': '执行编码',
              'state': 'done',
            },
          ],
          artifacts: <Map<String, dynamic>>[
            _artifact('art_diff', 'diff'),
            _artifact('art_log', 'run_log'),
            _artifact('art_summary', 'change_summary'),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('运行日志'), findsOneWidget);
    expect(find.text('改动摘要'), findsOneWidget);
    expect(find.text('改动补丁'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('运行日志')).dy,
      lessThan(tester.getTopLeft(find.text('改动摘要')).dy),
      reason: '任务结束后最先要看的是运行日志',
    );
    expect(
      tester.getTopLeft(find.text('改动摘要')).dy,
      lessThan(tester.getTopLeft(find.text('改动补丁')).dy),
    );

    await tester.pumpWidget(const SizedBox());
  });
}
