import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/core/ui/conversation_icon.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假服务端：会话页一进来就要拉历史与详情，菜单动作又打 PATCH / DELETE，
/// 用一张按路径分派的表把它们分开，顺便把请求都记下来供断言。
class _FakeServer {
  _FakeServer({
    this.deleteStatus = 204,
    this.deleteHint = '',
    this.detailTitle = '旧名字',
  });

  /// 删除接口的状态码：非 2xx 时按统一错误体返回 [deleteHint]。
  final int deleteStatus;
  final String deleteHint;

  /// 会话详情里服务端返回的标题：与页面拿到的初始标题不同即可模拟自动生成。
  final String detailTitle;

  final List<http.Request> requests = <http.Request>[];

  static const Map<String, String> _headers = <String, String>{
    'content-type': 'application/json; charset=utf-8',
  };

  Map<String, dynamic> _conversation(String title) => <String, dynamic>{
    'id': 'conv-1',
    'project_id': 'w1',
    'title': title,
    'mode': 'text',
    'archived': false,
    'created_at': 0,
    'updated_at': 0,
  };

  MockClient get client => MockClient((http.Request request) async {
    requests.add(request);
    final path = request.url.path;

    if (request.method == 'GET' && path.endsWith('/messages')) {
      return http.Response(
        jsonEncode(<String, dynamic>{'items': <dynamic>[]}),
        200,
        headers: _headers,
      );
    }
    if (request.method == 'GET') {
      return http.Response(
        jsonEncode(_conversation(detailTitle)),
        200,
        headers: _headers,
      );
    }
    if (request.method == 'PATCH') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode(_conversation(body['title'] as String)),
        200,
        headers: _headers,
      );
    }

    if (deleteStatus >= 300) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'code': 'conflict',
          'message': 'conflict',
          'retryable': false,
          'hint': deleteHint,
        }),
        deleteStatus,
        headers: _headers,
      );
    }
    return http.Response('', 204);
  });
}

Widget _harness(
  _FakeServer server, {
  String title = '旧名字',
  ChatPresentation presentation = ChatPresentation.docked,
  VoidCallback? onClose,
  ValueChanged<String>? onRenamed,
  VoidCallback? onDeleted,
}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: server.client,
        ),
      ),
    ],
    child: MaterialApp(
      home: ChatPage(
        conversationId: 'conv-1',
        title: title,
        presentation: presentation,
        onClose: onClose,
        onRenamed: onRenamed,
        onDeleted: onDeleted,
      ),
    ),
  );
}

/// 进页面后等历史与标题这两个请求落地，再交给后续断言。
///
/// 不用 `pumpAndSettle`：会话页在加载态里有个常转的进度环，settle 会一直等下去。
Future<void> _openPage(WidgetTester tester, Widget harness) async {
  await tester.pumpWidget(harness);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('会话操作'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('整页形态：页头标题只有文字，不再带会话图标', (tester) async {
    await _openPage(
      tester,
      _harness(_FakeServer(), presentation: ChatPresentation.page),
    );

    expect(find.text('旧名字'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(conversationIcon),
      ),
      findsNothing,
      reason: '页头标题左侧不再放对话气泡，标题自己就够说明这是哪条会话',
    );
  });

  testWidgets('「…」菜单是关闭 / 重命名 / 删除会话，点关闭交给外壳', (tester) async {
    var closed = false;
    await _openPage(tester, _harness(_FakeServer(), onClose: () => closed = true));

    await _openMenu(tester);

    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('关闭')).dy,
      lessThan(tester.getTopLeft(find.text('重命名')).dy),
      reason: '「关闭」排在最上面',
    );
    expect(
      tester.getTopLeft(find.text('重命名')).dy,
      lessThan(tester.getTopLeft(find.text('删除会话')).dy),
    );

    await tester.tap(find.text('关闭'));
    await tester.pump();
    expect(closed, isTrue, reason: '关闭该由外壳决定落到哪儿');
  });

  testWidgets('重命名走 PATCH，栏头与外壳标题一起更新', (tester) async {
    final server = _FakeServer();
    String? renamed;
    await _openPage(
      tester,
      _harness(server, onRenamed: (String title) => renamed = title),
    );

    await _openMenu(tester);
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('重命名会话'), findsOneWidget);

    // 只填对话框里的那一个输入框：页面底部还有聊天输入框。
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '  新名字  ',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final patch = server.requests
        .where((http.Request request) => request.method == 'PATCH')
        .single;
    expect(patch.url.path, '/api/conversations/conv-1');
    expect(
      (jsonDecode(patch.body) as Map<String, dynamic>)['title'],
      '新名字',
      reason: '提交前 trim，别把首尾空格存进去',
    );

    expect(renamed, '新名字', reason: '外壳要拿新标题去刷新侧栏与栏头');
    expect(find.text('新名字'), findsOneWidget, reason: '栏头标题当场换掉');
    expect(find.text('旧名字'), findsNothing);
  });

  testWidgets('回车直接提交重命名，和点「保存」一样', (tester) async {
    final server = _FakeServer();
    String? renamed;
    await _openPage(
      tester,
      _harness(server, onRenamed: (String title) => renamed = title),
    );

    await _openMenu(tester);
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '回车名字',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(server.requests.where((http.Request r) => r.method == 'PATCH'), hasLength(1));
    expect(renamed, '回车名字');
    expect(find.text('回车名字'), findsOneWidget);
  });

  testWidgets('服务端自动生成的标题也要报给外壳，侧栏才不会停在「新会话」', (tester) async {
    // 自动标题不走 PATCH：客户端只是回读详情时发现变了。
    final server = _FakeServer(detailTitle: '现在几点了');
    String? renamed;
    await _openPage(
      tester,
      _harness(
        server,
        title: defaultConversationTitle,
        onRenamed: (String title) => renamed = title,
      ),
    );

    expect(renamed, '现在几点了', reason: '不通知外壳，侧栏那份列表缓存就一直是「新会话」');
    expect(find.text('现在几点了'), findsOneWidget, reason: '栏头跟着换');
  });

  testWidgets('删除会话先二次确认，成功后才发 DELETE 并通知外壳', (tester) async {
    final server = _FakeServer();
    var deleted = false;
    await _openPage(tester, _harness(server, onDeleted: () => deleted = true));

    await _openMenu(tester);
    await tester.tap(find.text('删除会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('删除「旧名字」？'), findsOneWidget);
    expect(
      server.requests.where((http.Request r) => r.method == 'DELETE'),
      isEmpty,
      reason: '确认之前不能动数据',
    );

    await tester.tap(find.text('删除 1 项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final delete = server.requests
        .where((http.Request request) => request.method == 'DELETE')
        .single;
    expect(delete.url.path, '/api/conversations/conv-1');
    expect(deleted, isTrue, reason: '删完要让外壳刷列表并切回项目');
  });

  testWidgets('删除失败（会话下还有未结束任务）只弹提示，页面不动', (tester) async {
    final server = _FakeServer(
      deleteStatus: 409,
      deleteHint: '会话下还有未结束的任务，请先取消或等它结束再删会话',
    );
    var deleted = false;
    await _openPage(tester, _harness(server, onDeleted: () => deleted = true));

    await _openMenu(tester);
    await tester.tap(find.text('删除会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('删除 1 项'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('会话下还有未结束的任务，请先取消或等它结束再删会话'), findsOneWidget);
    expect(deleted, isFalse);
    expect(find.text('旧名字'), findsOneWidget, reason: '删失败就还留在会话页');
  });
}
