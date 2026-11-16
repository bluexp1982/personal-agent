import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillEditor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:jarvis_app/src/features/conversations/composer_text.dart';
import 'package:jarvis_app/src/features/conversations/file_artifact_card.dart';

/// 假服务端：每轮问答开一条独立的 SSE 流，推送时机由用例控制。
///
/// 与 `chat_stop_test.dart` 的假服务端同构，区别只在于"一人一条流"：
/// 这里要连发两轮，复用同一条已被关闭的流会在第二轮直接抛错。
class _FakeServer {
  final List<StreamController<List<int>>> _streams =
      <StreamController<List<int>>>[];

  /// 覆盖决策请求的 body，用例可断言客户端确实发了请求。
  final List<String> decideBodies = <String>[];

  static const Map<String, String> _jsonHeaders = <String, String>{
    'content-type': 'application/json; charset=utf-8',
  };

  late final http.Client client = MockClient.streaming(_handle);

  StreamController<List<int>> get _current => _streams.last;

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream _,
  ) async {
    final path = request.url.path;

    if (request.method == 'POST' && path.endsWith('/messages')) {
      final stream = StreamController<List<int>>();
      _streams.add(stream);
      return http.StreamedResponse(
        stream.stream,
        200,
        headers: const <String, String>{'content-type': 'text/event-stream'},
      );
    }

    if (request.method == 'POST' && path.contains('/file-writes/')) {
      final body = jsonDecode((request as http.Request).body);
      decideBodies.add(jsonEncode(body));
      final id = path.split('/file-writes/').last;
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'request_id': id,
              'path': 'README.md',
              'scope': 'project',
              'status': 'written',
              'bytes': 9888,
              'existing_bytes': 6142,
              'backup_path': '/data/file-backups/conv-1/$id/README.md',
              'created_at': 1793968494379,
            }),
          ),
        ),
        200,
        headers: _jsonHeaders,
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
    _current.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
  }

  /// 结束当前这一轮（服务端正常收尾），下一轮会另开一条流。
  void finishTurn() {
    unawaited(_current.close());
  }

  void closeAll() {
    for (final stream in _streams) {
      unawaited(stream.close());
    }
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

/// 推进到页面就绪：历史加载空列表、输入框可输入。
Future<void> _open(WidgetTester tester, _FakeServer server) async {
  await tester.pumpWidget(_harness(server));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 发一句话，等 POST 挂上流。
///
/// 输入栏是 Quill 富文本，`enterText` 找不到可写的 `TextField`：
/// 直接往 controller 里写，等价于用户敲进去（既有聊天测试也是这么做的）。
Future<void> _send(WidgetTester tester) async {
  final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
  setComposerText(editor.controller, '写点什么');
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  await tester.pump();
}

/// 点卡片上的「覆盖」。
///
/// 回答区是可滚动的：卡片落在可视区外时直接 `tap` 会打到输入栏上，
/// 所以先把它滚进视野——这也更接近真实用户的操作。
Future<void> _tapApprove(WidgetTester tester) async {
  final approve = find.text('覆盖');
  await tester.ensureVisible(approve);
  await tester.pump();
  await tester.tap(approve);
  await tester.pump();
  await tester.pump();
}

/// 收尾一轮：关流后等客户端把"生成中"解掉。
Future<void> _finishTurn(WidgetTester tester, _FakeServer server) async {
  server.finishTurn();
  await tester.pump();
  await tester.pump(streamFlushInterval);
}

/// 一轮"目标已存在"的写入：先推待确认事件，再推完成事件。
void _pushPendingWriteTurn(_FakeServer server) {
  server.push(<String, dynamic>{
    'type': 'file_write_request',
    'id': 'fw-1',
    'path': 'README.md',
    'scope': 'project',
    'existing_bytes': 6142,
    'new_bytes': 9888,
    'expires_at': DateTime.now().millisecondsSinceEpoch + 300000,
  });
  server.push(<String, dynamic>{
    'type': 'message_delta',
    'text': 'README 需要补的内容已核对完，现在按实际目录重写。',
  });
  server.push(<String, dynamic>{
    'type': 'message_completed',
    'message_id': 'msg-1',
    'finish_reason': 'stop',
    'elapsed_ms': 12000,
    'file_writes': <Map<String, dynamic>>[
      <String, dynamic>{
        'request_id': 'fw-1',
        'path': 'README.md',
        'scope': 'project',
        'status': 'pending',
        'bytes': 9888,
        'existing_bytes': 6142,
        'expires_at': DateTime.now().millisecondsSinceEpoch + 300000,
        'created_at': 1793968494379,
      },
    ],
    'steps': <Map<String, dynamic>>[
      <String, dynamic>{
        'tool': 'write_file',
        'label': '已写入 README.md',
        'target': 'write_file:README.md',
        'ok': true,
        'elapsed_ms': 5,
      },
    ],
  });
}

/// 一轮只读的回答：没有任何 `file_writes`，只有执行过程。
void _pushReadOnlyTurn(_FakeServer server) {
  server.push(<String, dynamic>{
    'type': 'message_completed',
    'message_id': 'msg-2',
    'finish_reason': 'stop',
    'elapsed_ms': 12000,
    'steps': <Map<String, dynamic>>[
      <String, dynamic>{
        'tool': 'list_dir',
        'label': '已查看目录',
        'target': 'dir:',
        'ok': true,
        'elapsed_ms': 0,
      },
      <String, dynamic>{
        'tool': 'search_content',
        'label': '已搜索内容 6 处命中',
        'target': 'search:11:mode=content:hits=6',
        'ok': true,
        'elapsed_ms': 17,
      },
      <String, dynamic>{
        'tool': 'read_file',
        'label': '已读取 README.md',
        'target': 'file:README.md:24-37',
        'ok': true,
        'elapsed_ms': 0,
      },
    ],
  });
}

void main() {
  testWidgets('上一轮已确认的写入卡不会并进下一轮只读回答', (tester) async {
    final server = _FakeServer();
    addTearDown(server.closeAll);

    await _open(tester, server);

    // 第一轮：覆盖已存在的 README，卡片先是待确认。
    await _send(tester);
    _pushPendingWriteTurn(server);
    await tester.pump();
    await tester.pump(streamFlushInterval);
    expect(find.text('要覆盖已有文件'), findsOneWidget);
    expect(find.text('待确认覆盖'), findsOneWidget);

    await _finishTurn(tester, server);

    // 用户点了覆盖：服务端回写盘结果，卡片就地变成"已写入"。
    await _tapApprove(tester);
    expect(server.decideBodies.length, 1, reason: '决策要真的打到服务端');
    expect(find.text('已写入'), findsOneWidget);
    expect(find.byType(FileWriteArtifactCard), findsOneWidget);

    // 第二轮：只读、没有 file_writes。这一轮不该凭空多出一张产物卡。
    await _send(tester);
    _pushReadOnlyTurn(server);
    await tester.pump();
    await tester.pump(streamFlushInterval);

    expect(
      find.byType(FileWriteArtifactCard),
      findsOneWidget,
      reason: '只该留第一轮那张：上一轮的已写入卡不能跨轮带过来',
    );
    expect(find.text('已写入'), findsOneWidget);

    await _finishTurn(tester, server);
  });

  testWidgets('收尾后确认只更新消息里的那张卡，不叠出第二张、状态也不回退', (tester) async {
    final server = _FakeServer();
    addTearDown(server.closeAll);

    await _open(tester, server);

    await _send(tester);
    _pushPendingWriteTurn(server);
    await tester.pump();
    await tester.pump(streamFlushInterval);
    await _finishTurn(tester, server);

    // 收尾之后点覆盖：只该更新消息里那张卡。
    await _tapApprove(tester);
    expect(server.decideBodies.length, 1);
    expect(find.byType(FileWriteArtifactCard), findsOneWidget);
    expect(find.text('已写入'), findsOneWidget);
    expect(find.text('待确认覆盖'), findsNothing);
  });
}
