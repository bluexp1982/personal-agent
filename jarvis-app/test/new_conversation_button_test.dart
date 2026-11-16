import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/project_providers.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/new_conversation_icon.dart';
import 'package:jarvis_app/src/features/shell/rail_navigator.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

const Map<String, String> _headers = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

List<Project> _twoProjects() => const <Project>[
  Project(
    id: 'w1',
    name: 'hello-demo',
    mode: ProjectModes.work,
    path: '/tmp/hello-demo',
    conversationCount: 0,
    taskCount: 0,
  ),
  Project(
    id: 'w2',
    name: '周报整理',
    mode: ProjectModes.work,
    path: '/tmp/weekly',
    conversationCount: 0,
    taskCount: 0,
  ),
];

/// 假服务端：只认「新建会话」这一路真正需要的几个端点。
///
/// `posted` 收下每一次 `POST /api/conversations` 的请求体，用例据此断言
/// "会话落到了哪个项目"——这是本次功能唯一不可从界面读出的结果。
class _Server {
  _Server(this.projects);

  final List<Project> projects;
  final List<Map<String, dynamic>> posted = <Map<String, dynamic>>[];

  http.Client get client => MockClient((http.Request request) async {
    final path = request.url.path;
    if (request.method == 'POST' && path == '/api/conversations') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      posted.add(body);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': 'c-new',
          'title': '新会话',
          'project_id': body['project_id'],
          'mode': 'work',
          'archived': false,
          'created_at': 0,
          'updated_at': 0,
        }),
        200,
        headers: _headers,
      );
    }
    // 新建后会话页会拉历史；空列表就够它落掉加载态。
    if (path.endsWith('/messages')) {
      return http.Response(
        jsonEncode(<String, dynamic>{'items': <dynamic>[]}),
        200,
        headers: _headers,
      );
    }
    if (path.startsWith('/api/projects/')) {
      final id = path.split('/').last;
      final project = projects.firstWhere(
        (item) => item.id == id,
        orElse: () => projects.first,
      );
      return http.Response(
        jsonEncode(<String, dynamic>{
          'id': project.id,
          'name': project.name,
          'mode': project.mode,
          'path': project.path,
          'conversation_count': project.conversationCount,
          'task_count': project.taskCount,
          'updated_at': project.updatedAt,
        }),
        200,
        headers: _headers,
      );
    }
    if (path == '/api/conversations') {
      return http.Response(
        jsonEncode(<String, dynamic>{'items': <dynamic>[]}),
        200,
        headers: _headers,
      );
    }
    return http.Response(
      jsonEncode(<String, dynamic>{
        'id': 'c-new',
        'project_id': 'w1',
        'title': '新会话',
        'mode': 'work',
        'archived': false,
        'created_at': 0,
        'updated_at': 0,
      }),
      200,
      headers: _headers,
    );
  });
}

Widget _harness(_Server server) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: server.client,
        ),
      ),
      // 项目列表直接给固定值：本用例关心的是"落到哪一个"，不是列表怎么来。
      projectsProvider.overrideWith((ref) => server.projects),
    ],
    child: const MaterialApp(home: HomeShell(session: _session)),
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 宽屏骨架 + 收起左栏：栏头那枚按钮只在收起后才存在。
Future<void> _openCollapsed(WidgetTester tester, _Server server) async {
  await _setSurface(tester, const Size(1280, 800));
  await tester.pumpWidget(_harness(server));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(kRailToggleKey));
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

void main() {
  testWidgets('左栏展开时不出现：入口就在侧栏那枚整行按钮上', (tester) async {
    await _setSurface(tester, const Size(1280, 800));
    await tester.pumpWidget(_harness(_Server(_twoProjects())));
    await tester.pumpAndSettle();

    expect(find.byKey(kNewConversationKey), findsNothing);
  });

  testWidgets('左栏收起后排在导航按钮之后，尺寸与栏头同一套', (tester) async {
    await _openCollapsed(tester, _Server(_twoProjects()));

    expect(find.byKey(kNewConversationKey), findsOneWidget);

    final toggle = tester.getRect(find.byKey(kRailToggleKey));
    final back = tester.getRect(find.byKey(kRailBackKey));
    final forward = tester.getRect(find.byKey(kRailForwardKey));
    final button = tester.getRect(find.byKey(kNewConversationKey));
    expect(back.left, greaterThanOrEqualTo(toggle.right), reason: '后退紧跟显示左栏按钮');
    expect(forward.left, greaterThanOrEqualTo(back.right), reason: '前进在后退右侧');
    expect(
      button.left,
      greaterThanOrEqualTo(forward.right),
      reason: '新建会话排在导航按钮之后，不能压住它们',
    );
    expect(
      button.size,
      const Size.square(kPaneHeaderButtonSize),
      reason: '命中区应与栏头其他图标按钮一致',
    );
    expect(
      tester.getSize(
        find.descendant(
          of: find.byKey(kNewConversationKey),
          matching: find.byType(NewConversationIcon),
        ),
      ),
      const Size.square(kPaneHeaderIconSize),
      reason: '图标尺寸应与栏头一致',
    );
  });

  testWidgets('一个项目都没有时照样可用：建一条不挂项目的对话', (tester) async {
    final server = _Server(const <Project>[]);
    await _openCollapsed(tester, server);

    final button = tester.widget<IconButton>(find.byKey(kNewConversationKey));
    expect(button.onPressed, isNotNull, reason: '聊天不必挂在目录上，按钮不该再置灰');
    expect(find.byTooltip('新开一条无项目的对话'), findsOneWidget);

    await tester.tap(find.byKey(kNewConversationKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    expect(server.posted, hasLength(1));
    expect(
      server.posted.single.containsKey('project_id'),
      isFalse,
      reason: '无归属会话不传 project_id',
    );
    final target = _container(tester).read(shellTargetProvider);
    expect(target, isA<ConversationTarget>());
    expect((target! as ConversationTarget).projectId, isEmpty);
  });

  testWidgets('点击后落到当前选中项所在项目，并切到新会话', (tester) async {
    final server = _Server(_twoProjects());
    await _openCollapsed(tester, server);

    // 选中第二个项目：新会话要跟着它走，而不是永远落在列表第一个。
    _container(tester)
        .read(shellTargetProvider.notifier)
        .select(ProjectTarget(server.projects[1]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kNewConversationKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    expect(server.posted, hasLength(1));
    expect(server.posted.single['project_id'], 'w2');

    final container = _container(tester);
    final target = container.read(shellTargetProvider);
    expect(target, isA<ConversationTarget>());
    final conversation = target! as ConversationTarget;
    expect(conversation.projectId, 'w2');
    expect(conversation.conversationId, 'c-new');
    expect(
      container.read(railCollapsedProvider),
      isTrue,
      reason: '用户收起左栏是主动选择，新建会话不该把它强行展开',
    );
  });

  testWidgets('没有选中项时落到列表第一个项目', (tester) async {
    final server = _Server(_twoProjects());
    await _openCollapsed(tester, server);

    await tester.tap(find.byKey(kNewConversationKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    expect(server.posted.single['project_id'], 'w1');
  });

  testWidgets('窄屏单列没有这条栏头，也就没有这颗按钮', (tester) async {
    await _setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_harness(_Server(_twoProjects())));
    await tester.pumpAndSettle();

    expect(find.byKey(kNewConversationKey), findsNothing);
  });

  testWidgets('侧栏项目行的「新会话」落到它自己的项目，而不是当前选中项', (tester) async {
    final server = _Server(_twoProjects());
    await _setSurface(tester, const Size(1280, 800));
    await tester.pumpWidget(_harness(server));
    await tester.pumpAndSettle();

    // 行尾按钮只在悬停时浮出来。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('周报整理')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(railProjectNewConversationKey('w2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    expect(server.posted, hasLength(1));
    expect(
      server.posted.single['project_id'],
      'w2',
      reason: '点哪一行的按钮就落到哪个项目，不看当前选中项',
    );

    final target = _container(tester).read(shellTargetProvider);
    expect(target, isA<ConversationTarget>());
    final conversation = target! as ConversationTarget;
    expect(conversation.projectId, 'w2');
    expect(conversation.conversationId, 'c-new');
  });
}
