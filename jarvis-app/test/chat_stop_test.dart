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

/// 假服务端：把 SSE 的推送时机交给用例。
///
/// 普通 `MockClient` 只能一次性返回完整响应，测不了"生成到一半点停止"；
/// 这里用 `MockClient.streaming` 挂一条自己控制的字节流。
class _FakeServer {
  final List<String> stopBodies = <String>[];
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

    if (request.method == 'POST' && path.endsWith('/stop')) {
      // 直接读 `Request.body`，不去消费 bodyStream：测试里少一层异步等待。
      final body = jsonDecode((request as http.Request).body);
      stopBodies.add((body as Map<String, dynamic>)['client_msg_id'] as String);
      return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
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

  /// 推一条 SSE 事件。
  void push(Map<String, dynamic> event) {
    _sse.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
  }

  /// 制造一次传输层错误，模拟连接中途断掉。
  void fail(Object error) => _sse.addError(error);

  void close() {
    // 不 await：`close()` 要等 done 事件送出去，而测试里那需要 pump 才会发生。
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

/// 进入页面、发一句话、等第一片文字落地。
Future<void> _openAndSend(WidgetTester tester, _FakeServer server) async {
  await tester.pumpWidget(_harness(server));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  await tester.enterText(find.byType(TextField), '写点什么');
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  await tester.pump();

  server.push(<String, dynamic>{'type': 'message_delta', 'text': '第一句。'});
  await tester.pump();
  // 增量按 80ms 合并一次，得等它 flush 才会出现在界面上。
  await tester.pump(streamFlushInterval);
}

void main() {
  testWidgets('生成中按钮变成停止，点击后由服务端收尾并标记已停止', (tester) async {
    final server = _FakeServer();
    addTearDown(server.close);

    await _openAndSend(tester, server);
    expect(find.text('生成中…'), findsOneWidget);
    expect(find.byTooltip('停止生成'), findsOneWidget);

    await tester.tap(find.byTooltip('停止生成'));
    await tester.pump();

    // 停止走的是接口而不是断流：客户端断开在服务端等于"丢弃半截回答"。
    expect(server.stopBodies.length, 1, reason: '点停止必须真的请求服务端');
    expect(server.stopBodies.single, startsWith('c'));

    // 服务端收尾：流自己结束，半截回答带上 finish_reason=stopped
    server.push(<String, dynamic>{
      'type': 'message_completed',
      'message_id': 'msg-1',
      'finish_reason': 'stopped',
      'elapsed_ms': 1200,
    });
    server.close();
    await tester.pump();
    await tester.pump(streamFlushInterval);

    expect(find.textContaining('已停止'), findsOneWidget);
    expect(find.text('生成失败'), findsNothing);
    // 回答走 Markdown 渲染，正文是 RichText，得把 rich text 也算上。
    expect(find.textContaining('第一句。', findRichText: true), findsWidgets);
    expect(find.byTooltip('发送'), findsOneWidget, reason: '收尾后按钮要恢复成发送');
  });

  testWidgets('服务端迟迟不确认时，兜底超时也会解锁并标记已停止', (tester) async {
    final server = _FakeServer();
    addTearDown(server.close);

    await _openAndSend(tester, server);
    await tester.tap(find.byTooltip('停止生成'));
    await tester.pump();

    // 服务端既不推完成事件、也不关流：界面不能一直停在"生成中"。
    await tester.pump(stopFallbackDelay + const Duration(milliseconds: 50));

    expect(find.textContaining('已停止'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
  });

  testWidgets('流中途报错时界面照样解锁并标失败', (tester) async {
    final server = _FakeServer();
    addTearDown(server.close);

    await _openAndSend(tester, server);
    server.fail(Exception('连接被重置'));
    await tester.pump();
    await tester.pump();

    expect(find.text('生成失败'), findsOneWidget);
    expect(
      find.byTooltip('发送'),
      findsOneWidget,
      reason: '出错后也必须退出"生成中"，否则输入框永远发不出下一条',
    );
  });
}
