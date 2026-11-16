import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Map<String, String> _headers = <String, String>{
  'content-type': 'application/json; charset=utf-8',
};

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: _headers);

/// 30 条足够长的消息：一屏放不下，滚动条与"离开底部"才有意义。
Map<String, dynamic> _message(int index) => <String, dynamic>{
  'id': 'msg-$index',
  'role': index.isEven ? 'user' : 'assistant',
  'content': '第 $index 条消息，用来把列表撑得足够长以便滚动。' * 3,
  'created_at': 1790000000000 + index * 1000,
};

Widget _harness() {
  final client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/messages')) {
      return _json(<String, dynamic>{
        'items': <dynamic>[
          for (var index = 0; index < 30; index++) _message(index),
        ],
      });
    }
    return _json(<String, dynamic>{
      'id': 'conv-1',
      'project_id': 'w1',
      'title': '长会话',
      'mode': 'text',
      'archived': false,
      'created_at': 0,
      'updated_at': 0,
    });
  });

  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: client,
        ),
      ),
    ],
    child: const MaterialApp(
      home: ChatPage(
        conversationId: 'conv-1',
        title: '长会话',
        presentation: ChatPresentation.docked,
      ),
    ),
  );
}

/// 浮标常驻树里、靠透明度显隐，所以断言的是透明度而不是"找得到找不到"。
double _jumpOpacity(WidgetTester tester) {
  return tester.widget<AnimatedOpacity>(find.byKey(jumpToBottomKey)).opacity;
}

/// 现画一张真 PNG：图片要真的能解码，走的是与线上一致的那条路径。
Future<Uint8List> _makePng(int size) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 末尾压一条带 1328×1328 图片的助手消息。
///
/// 这张图的占位块如果按列宽铺满（1:1 图在 688dp 宽的列里就是 688 高），字节
/// 到达后成品只有 280 高，列表会先按骨架高度滚到底、再被"变矮"顶出底部之外，
/// 然后由弹性物理慢慢弹回来——用户看到的就是会话详情页一直在抽动。
Map<String, dynamic> _imageMessage() => <String, dynamic>{
  'id': 'msg-image',
  'role': 'assistant',
  'content': '画好了：一只橘猫摊在窗台上打瞌睡。',
  'created_at': 1790000099000,
  'media': <dynamic>[
    <String, dynamic>{
      'id': 'img_1',
      'kind': 'image',
      'mime': 'image/png',
      'bytes': 2511276,
      'model': 'qwen-image-3.0',
      'prompt': '窗台上的橘猫',
      'width': 1328,
      'height': 1328,
    },
  ],
};

Widget _mediaHarness(Uint8List png) {
  final client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/messages')) {
      return _json(<String, dynamic>{
        'items': <dynamic>[
          for (var index = 0; index < 30; index++) _message(index),
          _imageMessage(),
        ],
      });
    }
    if (request.url.path.contains('/api/media/')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response.bytes(
        png,
        200,
        headers: <String, String>{'content-type': 'image/png'},
      );
    }
    return _json(<String, dynamic>{
      'id': 'conv-1',
      'project_id': 'w1',
      'title': '长会话',
      'mode': 'text',
      'archived': false,
      'created_at': 0,
      'updated_at': 0,
    });
  });

  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: 'http://127.0.0.1:8787',
          token: 'token-1',
          httpClient: client,
        ),
      ),
    ],
    child: const MaterialApp(
      home: ChatPage(
        conversationId: 'conv-1',
        title: '长会话',
        presentation: ChatPresentation.docked,
      ),
    ),
  );
}

/// 打开页面并等历史、标题两个请求落地。
///
/// 不用 `pumpAndSettle`：进来先有一个常转的进度环，settle 会一直等下去。
Future<void> _openPage(WidgetTester tester) async {
  await tester.pumpWidget(_harness());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  late Uint8List png;

  setUpAll(() async {
    png = await _makePng(160);
  });

  testWidgets('贴底时不显示浮标，往上翻之后浮出，点击回到底部', (tester) async {
    await _openPage(tester);

    expect(_jumpOpacity(tester), 0, reason: '进页面即贴底，不该出现浮标');

    // 往上翻 600 像素：离开底部。
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_jumpOpacity(tester), 1, reason: '离开底部后应浮出浮标');

    await tester.tap(find.byKey(jumpToBottomKey));
    // 滚回去是 180ms 的动画 + 浮标 150ms 淡出：让它们自然跑完。
    await tester.pumpAndSettle();

    expect(_jumpOpacity(tester), 0, reason: '回到底部后应自动隐藏');
  });

  testWidgets('含图片的会话进页面即贴底，图片到达后不越过底部', (tester) async {
    await tester.pumpWidget(_mediaHarness(png));
    // 历史 → 首帧（图片还是骨架）→ 字节到达 → 成品替换，多走几帧让这些全部落地。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    final position =
        tester.widget<ListView>(find.byType(ListView)).controller!.position;
    expect(position.maxScrollExtent, greaterThan(0), reason: '这条会话要能滚');
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: '进页面就该落在底部',
    );
    expect(
      position.pixels,
      lessThanOrEqualTo(position.maxScrollExtent + 1),
      reason: '不许越过底部：越界之后只能靠回弹清算，看着就是抽动',
    );
    expect(_jumpOpacity(tester), 0, reason: '贴底时不该浮出「回到底部」');

    // 再走几帧：如果还留着越界回弹，像素会继续动。
    final settled = position.pixels;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(position.pixels, closeTo(settled, 1), reason: '位置应当已经停稳');
  });
}
