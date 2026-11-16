import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/project_providers.dart';
import 'package:jarvis_app/src/features/conversations/at_skill_provider.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:jarvis_app/src/features/conversations/conversations_page.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';
import 'package:jarvis_app/src/features/conversations/new_session_stage.dart';
import 'package:jarvis_app/src/features/conversations/pending_chat_message.dart';
import 'package:jarvis_app/src/features/conversations/task_state_card.dart';
import 'package:jarvis_app/src/features/shell/empty_chat_page.dart';
import 'package:jarvis_app/src/features/shell/home_shell.dart';
import 'package:jarvis_app/src/features/shell/shell_layout_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const SessionState _session = SessionState(
  serverUrl: 'https://192.168.1.10:8787',
  deviceId: 'device-1',
  token: 'token-1',
);

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

/// 假服务端：只认「空态里发第一句」这条链路用到的端点。
///
/// `created` / `sent` 收下两个 POST 的请求体：用例据此断言"会话没有带项目"
/// 与"敲的那句话原样交给了会话页"——这两件事都读不出来，只能看请求。
class _Server {
  final List<Map<String, dynamic>> created = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// 收到的每个请求（`方法 路径`）。用它断言"到底走了哪条链路"——
  /// 光看返回码看不出：未知路径也会回一份会话 JSON。
  final List<String> paths = <String>[];

  late final http.Client client = MockClient.streaming(_handle);

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    final path = request.url.path;
    paths.add('${request.method} $path');

    if (request.method == 'POST' && path == '/api/conversations') {
      created.add(
        jsonDecode(utf8.decode(await body.toBytes())) as Map<String, dynamic>,
      );
      return _json(<String, dynamic>{
        'id': 'c-new',
        // 无归属会话在协议里用空串表达。
        'project_id': '',
        'title': '新会话',
        'mode': 'text',
        'archived': false,
        'created_at': 0,
        'updated_at': 0,
      });
    }

    if (request.method == 'POST' && path.endsWith('/messages')) {
      sent.add(
        jsonDecode(utf8.decode(await body.toBytes())) as Map<String, dynamic>,
      );
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[
          utf8.encode(
            'data: ${jsonEncode(<String, dynamic>{'type': 'message_delta', 'text': '好的'})}\n\n',
          ),
          utf8.encode(
            'data: ${jsonEncode(<String, dynamic>{'type': 'message_completed', 'message_id': 'm1'})}\n\n',
          ),
        ]),
        200,
        headers: const <String, String>{'content-type': 'text/event-stream'},
      );
    }

    // 历史、会话详情、无归属列表：空着就够让页面落掉加载态。
    if (path.endsWith('/messages')) {
      return _json(<String, dynamic>{'items': <dynamic>[]});
    }
    if (path == '/api/conversations') {
      return _json(<String, dynamic>{'items': <dynamic>[]});
    }
    return _json(<String, dynamic>{
      'id': 'c-new',
      'project_id': '',
      'title': '新会话',
      'mode': 'text',
      'archived': false,
      'created_at': 0,
      'updated_at': 0,
    });
  }

  http.StreamedResponse _json(Map<String, dynamic> body) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    200,
    headers: _jsonHeaders,
  );
}

Widget _harness({
  _Server? server,
  List<Project> projects = const <Project>[],
  List<ConversationSummary>? unassigned,
  List<SkillInfo> skills = const <SkillInfo>[],
}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        server == null
            ? null
            : ApiClient(
                baseUrl: 'http://127.0.0.1:8787',
                token: 'token-1',
                httpClient: server.client,
              ),
      ),
      projectsProvider.overrideWith((ref) => projects),
      if (unassigned != null)
        unassignedConversationsProvider.overrideWith((ref) => unassigned),
      // `@` 候选的技能清单：不覆盖会去请求真实 `/api/skills`，
      // 假服务端不认识那条路径，候选永远为空。
      atSkillsProvider.overrideWith((ref) async => skills),
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

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HomeShell)));

void main() {
  /// 空态页到会话页之间只交接"一句话 + 一个技能"。
  /// 技能必须跟着过去：它是富文本节点，转成纯文本后就没了，
  /// 只交文本会让"选了技能按回车"变成静默无事发生。
  test('交接能带上技能，且只有技能没有文字也算有效载荷', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final pending = container.read(pendingChatMessageProvider.notifier);

    pending.put('c1', '', skill: 'site-brief');
    final taken = pending.take('c1');
    expect(taken?.skill, 'site-brief');
    expect(taken?.text, isEmpty);

    // 空白且没有技能：不是一次有效发送，直接忽略。
    pending.put('c2', '   ');
    expect(pending.take('c2'), isNull);
  });

  testWidgets('宽屏空态就是聊天开场：标题「聊天」，探索未来在上、输入面板在下', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // 栏头标题说清这一栏在做什么：此刻还没有会话，所以不是「新会话」。
    expect(find.text(EmptyChatPage.title), findsOneWidget);
    expect(find.text('探索未来'), findsOneWidget);
    expect(find.byKey(kChatComposerPanelKey), findsOneWidget);
    // 旧引导卡整体下线：留着就说明新空态只是叠在了上面。
    expect(find.text('从左侧选择会话或项目'), findsNothing);
    expect(find.text('选一个会话开始对话，或选一个项目查看它的会话与任务。'), findsNothing);

    final brand = tester.getRect(find.text('探索未来'));
    final panel = tester.getRect(find.byKey(kChatComposerPanelKey));
    final pane = tester.getRect(find.byKey(kShellEmptyChatKey));

    // 居中的是输入栏本身：面板中点落在**整窗**中线上（栏头也算进窗口高度），
    // 水平也在栏中。贴底布局下这块会一路沉到窗口底部，中点远在中线以下。
    expect(panel.center.dy, closeTo(pane.center.dy, 4));
    expect(panel.center.dx, closeTo(pane.center.dx, 1));
    // 品牌行与输入栏之间只有一条固定间距：空态不再显示「当前模型」行，
    // 这条间距参与舞台的居中算式，所以按常量算而不是写死数字。
    expect(
      brand.bottom,
      closeTo(panel.top - NewSessionStage.brandGap, 2),
      reason: '品牌行 → 输入栏的间距固定',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('项目为空时同样渲染聊天开场，不退回项目引导', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(projects: const <Project>[]));
    await tester.pumpAndSettle();

    expect(find.byKey(kShellEmptyChatKey), findsOneWidget);
    expect(find.byKey(kChatComposerPanelKey), findsOneWidget);
    expect(find.text('还没有事务项目'), findsNothing, reason: '宽屏中栏不再放项目卡片');
    expect(tester.takeException(), isNull);
  });

  testWidgets('无归属直聊进侧栏「对话」分组，点开后中栏换成该会话', (tester) async {
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        unassigned: const <ConversationSummary>[
          ConversationSummary(
            id: 'c9',
            title: '随手一问',
            updatedAt: 0,
            projectId: '',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('对话'), findsOneWidget);
    expect(find.text('随手一问'), findsOneWidget);

    await tester.tap(find.text('随手一问'));
    // 会话页在没有客户端时会一直停在加载态（转圈不会停），所以不 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 中栏栏头也显示这个标题，所以两处各一份。
    expect(find.text('随手一问'), findsNWidgets(2));
    expect(find.byType(ChatPage), findsOneWidget);
    final target = _container(tester).read(shellTargetProvider);
    expect(target, isA<ConversationTarget>());
    expect((target! as ConversationTarget).projectId, isEmpty);
  });

  /// 复现用户报的场景：新会话页只选了技能、没打字，按回车。
  /// 修之前这里 `text` 为空会直接 return，整条消息发不出去。
  testWidgets('空态里只选技能也能发出去，且交接带上技能', (tester) async {
    final server = _Server();
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(server: server));
    await tester.pumpAndSettle();

    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    insertSkillEmbed(
      editor.controller,
      const SkillInfo(
        name: 'site-brief',
        version: '1.0.0',
        source: 'builtin',
        riskLevel: 'read',
        support: SkillSupport.supported,
        description: '读一个网页并摘要',
      ),
    );
    await tester.pump();
    expect(firstSkillName(editor.controller), 'site-brief', reason: '标签应插进文档');

    await tester.tap(find.byType(QuillEditor));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(server.created, hasLength(1), reason: '只选技能也该建会话');
    // 决定性证据：会话页接管后必须走"派任务"，而不是发一条普通消息。
    expect(
      server.paths,
      contains('POST /api/tasks/prepare'),
      reason: '带技能时应该解析参数，实际走了：${server.paths}',
    );
    expect(
      server.paths,
      isNot(contains('POST /api/conversations/c-new/messages')),
      reason: '带技能时不该再发一条普通消息',
    );
  });

  /// 完整复现用户路径：新会话页打 `@` → **点**候选行 → 回车。
  ///
  /// 不走 `insertSkillEmbed` 直接塞：那条路绕过了"面板能不能点到"，
  /// 而面板点不到正是之前"选了技能却什么都没发生"的真正原因。
  testWidgets('新会话页点候选行选技能，回车后走派任务', (tester) async {
    final server = _Server();
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(
      _harness(
        server: server,
        skills: const <SkillInfo>[
          SkillInfo(
            name: 'site-brief',
            version: '1.0.0',
            source: 'builtin',
            riskLevel: 'read',
            support: SkillSupport.supported,
            description: '读一个网页并摘要',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final controller = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    await tester.tap(find.byType(QuillEditor));
    await tester.pump();

    // 打一个 `@`，候选应弹出。
    controller.replaceText(
      0,
      0,
      '@',
      const TextSelection.collapsed(offset: 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('@site-brief'), findsOneWidget, reason: '候选应弹出');

    // 点候选行——这一步之前是"看着能点、其实点不到"。
    await tester.tap(find.text('@site-brief'));
    await tester.pumpAndSettle();
    expect(
      firstSkillName(controller),
      'site-brief',
      reason: '点候选行必须真的把标签插进文档',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(server.created, hasLength(1), reason: '应建会话');
    expect(
      server.paths,
      contains('POST /api/tasks/prepare'),
      reason: '应走派任务，实际走了：${server.paths}',
    );
    // 卡片必须真的画出来：只断言到 HTTP 层曾漏掉"舞台挡住列表"——
    // `@` 派任务不产生消息，`_messages` 为空时页面停在居中舞台，
    // 任务卡所在的列表根本没被构建，用户看到的就是"发送后一片空白"。
    expect(
      find.byType(AtTaskCard),
      findsOneWidget,
      reason: '派任务后任务卡必须出现在消息流里，不能被新会话舞台挡住',
    );
  });

  testWidgets('空态里发一句话：建无归属会话，首句交给会话页发出且只发一次', (tester) async {
    final server = _Server();
    await _setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(_harness(server: server));
    await tester.pumpAndSettle();

    // 编辑器是富文本：先点一下让它拿到焦点（Enter 是由焦点节点的
    // `onKeyEvent` 接的），再直接往 controller 里写，等价于用户敲进去。
    await tester.tap(find.byType(QuillEditor));
    await tester.pump();

    const sentence = '帮我订一张去上海的票';
    tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller
        .replaceText(
          0,
          0,
          sentence,
          const TextSelection.collapsed(offset: sentence.length),
        );
    await tester.pump();
    // Enter 走发送分支（与输入栏的键位约定一致）。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(server.created, hasLength(1));
    expect(
      server.created.single.containsKey('project_id'),
      isFalse,
      reason: '空态开的会话不挂项目',
    );

    final container = _container(tester);
    final target = container.read(shellTargetProvider);
    expect(target, isA<ConversationTarget>());
    expect((target! as ConversationTarget).conversationId, 'c-new');
    expect(
      (target as ConversationTarget).projectId,
      isEmpty,
      reason: '空串 = 无归属，侧栏「对话」分组据此收拢',
    );

    // 首句由会话页发出，且只发一次（交接是"取走即清空"）。
    expect(server.sent, hasLength(1));
    expect(server.sent.single['content'], '帮我订一张去上海的票');
    expect(container.read(pendingChatMessageProvider), isNull);
    expect(find.text('帮我订一张去上海的票'), findsOneWidget, reason: '气泡要当场出现');

    // 回答收尾后会挂一个 1.5s 的标题刷新延时；跑掉它，不留 pending timer。
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
