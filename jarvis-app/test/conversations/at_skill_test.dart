import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/at_skill_provider.dart';
import 'package:jarvis_app/src/features/conversations/task_state_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 会话里 `@技能` 的候选与卡片。

Map<String, dynamic> _skill(String name, String status, {List<String> tools = const <String>[]}) {
  return <String, dynamic>{
    'name': name,
    'version': '1.0.0',
    'source': 'builtin',
    'risk_level': 'read',
    'status': status,
    'required_tools': tools,
    'description': '$name 的说明',
  };
}

TaskView _task(String state) {
  return TaskView.fromJson(<String, dynamic>{
    'id': 'task_1',
    'conversation_id': 'conv_1',
    'type': 'skill:site-brief',
    'skill': 'site-brief',
    'state': state,
    'created_at': 0,
    'updated_at': 0,
  });
}

Widget _card(AtTaskView entry) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: AtTaskCard(entry: entry, onOpen: () {})),
    ),
  );
}

void main() {
  test('候选只保留能跑的非编码技能', () async {
    final client = MockClient(
      (http.Request request) async => http.Response(
        jsonEncode(<Map<String, dynamic>>[
          _skill('trip-plan', 'supported'),
          _skill('code-task', 'supported', tools: <String>['code.exec']),
          // 服务端现在会滤掉 unsupported，但客户端也要自己挡一道：
          // 版本错配时仍可能收到它。
          _skill('pdf-extract', 'unsupported'),
        ]),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: 'http://127.0.0.1:8787',
            token: 'token-1',
            httpClient: client,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final skills = await container.read(atSkillsProvider.future);
    expect(
      skills.map((skill) => skill.name).toList(),
      <String>['trip-plan'],
      reason: '编码任务与跑不了的技能都不该出现在 @ 候选里',
    );
  });

  testWidgets('卡片按任务状态显示对应徽标', (tester) async {
    for (final (state, label) in <(String, String)>[
      ('queued', '排队中'),
      ('running', '执行中'),
      ('needs_approval', '等你确认'),
      ('succeeded', '已完成'),
      ('failed', '失败'),
    ]) {
      final entry = AtTaskView(key: 'k', skill: 'site-brief')
        ..state = 'created'
        ..task = _task(state);

      await tester.pumpWidget(_card(entry));
      expect(find.text(label), findsOneWidget, reason: state);
    }
  });

  testWidgets('参数没解析出来时卡片明说，而不是假装参数齐了', (tester) async {
    final entry = AtTaskView(key: 'k', skill: 'site-brief')
      ..state = 'created'
      ..task = _task('running')
      ..missing = <String>['url'];

    await tester.pumpWidget(_card(entry));

    expect(find.textContaining('没解析出网址'), findsOneWidget);
    expect(find.textContaining('技能可能读不到资料'), findsOneWidget);
  });

  testWidgets('创建中与失败态各有自己的文案', (tester) async {
    final creating = AtTaskView(key: 'k1', skill: 'site-brief');
    await tester.pumpWidget(_card(creating));
    expect(find.text('创建中'), findsOneWidget);

    final failed = AtTaskView(key: 'k2', skill: 'site-brief')..state = 'failed';
    await tester.pumpWidget(_card(failed));
    expect(find.text('失败'), findsOneWidget);
    expect(find.textContaining('没派出去'), findsOneWidget);
  });
}
