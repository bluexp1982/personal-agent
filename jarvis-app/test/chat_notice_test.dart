import 'dart:async';
import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假服务端：只服务于"完成事件带不带 notice"这一件事。
///
/// 与 `chat_stop_test.dart` 同形：SSE 的推送时机交给用例控制，
/// 否则测不了"回答收尾时多出一条系统提示"。
class _FakeServer {
  final StreamController<List<int>> _sse = StreamController<List<int>>();

  static const Map<String, String> _jsonHeaders = <String, String>{
    'content-type': 'application/json; charset=utf-8',
  };

  late final http.Client client = MockClient.streaming(_handle);

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream _,
  ) async {
    final path = request.url.path;

    if (request.method == 'POST' && path.endsWith('/messages')) {
      return http.StreamedResponse(
        _sse.stream,
        200,
        headers: const <String, String>{'content-type': 'text/event-stream'},
      );
    }

    if (request.method == 'GET' && path.endsWith('/messages')) {
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(jsonEncode(<String, dynamic>{'items': <dynamic>[]})),
        ),
        200,
        headers: _jsonHeaders,
      );
    }

    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'id': 'conv-1',
            'project_id': 'w1',
            'title': '会话',
            'mode': 'text',
            'archived': false,
            'created_at': 0,
            'updated_at': 0,
          }),
        ),
      ),
      200,
      headers: _jsonHeaders,
    );
  }

  void push(Map<String, dynamic> event) {
    _sse.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
  }

  void close() {
    unawaited(_sse.close());
  }
}

Widget _harness(_FakeServer server) {
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
    child: const MaterialApp(
      home: ChatPage(
        conversationId: 'conv-1',
        title: '会话',
        presentation: ChatPresentation.docked,
      ),
    ),
  );
}

Future<void> _openAndSend(WidgetTester tester, _FakeServer server) async {
  await tester.pumpWidget(_harness(server));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  await tester.enterText(find.byType(TextField), '记住：我讨厌香菜');
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  await tester.pump();

  server.push(<String, dynamic>{'type': 'message_delta', 'text': '好的。'});
  await tester.pump();
  await tester.pump(streamFlushInterval);
}

void main() {
  testWidgets('完成事件带 notice 时追加一条居中系统提示', (tester) async {
    final server = _FakeServer();
    addTearDown(server.close);

    await _openAndSend(tester, server);
    server.push(<String, dynamic>{
      'type': 'message_completed',
      'message_id': 'msg-1',
      'finish_reason': 'stop',
      'elapsed_ms': 800,
      'notice': '已记住：我讨厌香菜',
    });
    server.close();
    await tester.pump();
    await tester.pump(streamFlushInterval);

    expect(find.text('已记住：我讨厌香菜'), findsOneWidget);
    // 回答本身还在：提示是插在回答之前的一条独立消息。
    expect(find.textContaining('好的。', findRichText: true), findsWidgets);
  });

  testWidgets('没有 notice 时不产生系统提示', (tester) async {
    final server = _FakeServer();
    addTearDown(server.close);

    await _openAndSend(tester, server);
    server.push(<String, dynamic>{
      'type': 'message_completed',
      'message_id': 'msg-1',
      'finish_reason': 'stop',
      'elapsed_ms': 800,
    });
    server.close();
    await tester.pump();
    await tester.pump(streamFlushInterval);

    expect(find.textContaining('已记住'), findsNothing);
  });
}
