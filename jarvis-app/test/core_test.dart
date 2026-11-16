import 'dart:convert';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/core/base32_codec.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/pairing_code.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('base32', () {
    test('编解码往返', () {
      final bytes = List<int>.generate(32, (index) => index * 7 % 256);
      final encoded = base32Encode(bytes);

      expect(encoded.length, 52, reason: '32 字节无 padding 编码为 52 字符');
      expect(base32Decode(encoded), bytes);
    });

    test('解码忽略大小写', () {
      expect(base32Decode('nbswy3dp'), base32Decode('NBSWY3DP'));
    });

    test('遇到非法字符抛 FormatException', () {
      expect(() => base32Decode('ABC!'), throwsFormatException);
    });

    test('与服务端一致的已知向量', () {
      // "hello" 的 RFC 4648 编码（无 padding）
      expect(base32Encode(utf8.encode('hello')), 'NBSWY3DP');
      expect(utf8.decode(base32Decode('NBSWY3DP')), 'hello');
    });
  });

  group('SSE', () {
    test('按空行切分事件并忽略注释', () async {
      final lines = Stream<String>.fromIterable(<String>[
        ': keep-alive',
        'data: {"type":"message_delta","text":"你"}',
        '',
        'data: {"type":"message_completed","message_id":"msg_1"}',
        '',
      ]);

      final events = await decodeSse(lines).toList();
      expect(events, hasLength(2));
      expect(events.first['type'], 'message_delta');
      expect(events.first['text'], '你');
      expect(events.last['message_id'], 'msg_1');
    });

    test('多行 data 会拼接后再解析', () async {
      final lines = Stream<String>.fromIterable(<String>[
        'data: {"type":"x",',
        'data: "value":1}',
        '',
      ]);

      final events = await decodeSse(lines).toList();
      expect(events, hasLength(1));
      expect(events.single['value'], 1);
    });

    test('结尾没有空行也能产出最后一条', () async {
      final lines = Stream<String>.fromIterable(<String>[
        'data: {"type":"done"}',
      ]);

      final events = await decodeSse(lines).toList();
      expect(events.single['type'], 'done');
    });
  });

  group('消息来源', () {
    test('从消息 JSON 解析来源', () {
      final message = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_1',
        'role': 'assistant',
        'content': '标题是 Example Domain。',
        'sources': <dynamic>[
          <String, dynamic>{
            'url': 'https://example.com/a/b',
            'fetched_at': 1700000000000,
          },
        ],
      });

      expect(message.sources, hasLength(1));
      expect(message.sources.first.url, 'https://example.com/a/b');
      expect(message.sources.first.fetchedAt, 1700000000000);
      // 卡片只显示主机名，路径留在悬停提示里
      expect(message.sources.first.host, 'example.com');
    });

    test('没有 sources 字段时为空列表而不是 null', () {
      final message = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_2',
        'role': 'user',
        'content': '你好',
      });

      expect(message.sources, isEmpty);
    });

    test('copyWith 保留来源', () {
      const source = MessageSource(url: 'https://example.com', fetchedAt: 1);
      const message = ChatMessage(
        id: 'msg_1',
        role: 'assistant',
        content: '旧',
        sources: <MessageSource>[source],
      );

      expect(message.copyWith(content: '新').sources, hasLength(1));
    });

    test('采集时间格式化成 MM-dd HH:mm', () {
      final time = DateTime(2026, 3, 5, 9, 7);
      final formatted = formatFetchedAt(time.millisecondsSinceEpoch);

      expect(formatted, '03-05 09:07');
      expect(formatFetchedAt(0), '时间未知');
    });

    test('主机名取不到时退回完整地址', () {
      const source = MessageSource(url: 'not a url', fetchedAt: 1);
      expect(source.host, 'not a url');
    });
  });

  group('消息建议', () {
    test('从消息 JSON 解析建议', () {
      final message = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_1',
        'role': 'assistant',
        'content': '要不要我直接排一下？',
        'task_suggestions': <dynamic>[
          <String, dynamic>{
            'skill': 'trip-plan',
            'reason': '你提到下周三去上海',
            'input': <String, dynamic>{'city': '上海'},
          },
        ],
      });

      expect(message.suggestions, hasLength(1));
      expect(message.suggestions.first.skill, 'trip-plan');
      expect(message.suggestions.first.input['city'], '上海');
    });

    test('没有建议字段或形状不对时为空列表', () {
      final none = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_1',
        'role': 'assistant',
        'content': '好',
      });
      expect(none.suggestions, isEmpty);

      final broken = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_2',
        'role': 'assistant',
        'content': '好',
        'task_suggestions': '不是数组',
      });
      expect(broken.suggestions, isEmpty);

      final noSkill = ChatMessage.fromJson(<String, dynamic>{
        'id': 'msg_3',
        'role': 'assistant',
        'content': '好',
        'task_suggestions': <dynamic>[
          <String, dynamic>{'reason': '缺技能名'},
        ],
      });
      expect(noSkill.suggestions, isEmpty);
    });

    test('copyWith 保留建议', () {
      const suggestion = TaskSuggestion(skill: 'trip-plan', reason: '理由');
      const message = ChatMessage(
        id: 'msg_1',
        role: 'assistant',
        content: '旧',
        suggestions: <TaskSuggestion>[suggestion],
      );

      expect(message.copyWith(content: '新').suggestions, hasLength(1));
    });
  });

  group('配对码', () {
    test('剥掉分组连字符与空白并统一大写', () {
      // `jarvis-service pair` 打印的就是分组形式，粘贴进客户端必须能直接用
      expect(normalizePairingCode('77JJ-VQ3F-2YZK'), '77JJVQ3F2YZK');
      expect(normalizePairingCode('  77jj vq3f 2yzk '), '77JJVQ3F2YZK');
      expect(normalizePairingCode('77JJVQ3F2YZK'), '77JJVQ3F2YZK');
    });

    test('归一化后 12 位才算合法', () {
      expect(isValidPairingCode('77JJ-VQ3F-2YZK'), isTrue);
      expect(isValidPairingCode('77JJVQ3F2YZK'), isTrue);
      expect(isValidPairingCode('ABC'), isFalse);
      expect(isValidPairingCode('77JJ-VQ3F-2YZK-XX'), isFalse);
    });
  });

  group('ApiException', () {
    test('解析统一错误体', () {
      final error = ApiException.fromResponse(
        401,
        '{"code":"unauthenticated","message":"m","retryable":false,"hint":"请重新登录"}',
      );

      expect(error.code, 'unauthenticated');
      expect(error.retryable, isFalse);
      expect(error.userMessage, '请重新登录');
    });

    test('非 JSON 响应退化为 internal_error 而不是抛异常', () {
      final error = ApiException.fromResponse(502, '<html>bad gateway</html>');

      expect(error.code, 'internal_error');
      expect(error.statusCode, 502);
    });
  });
}
