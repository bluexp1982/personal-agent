import 'package:jarvis_app/src/features/conversations/composer_reasoning.dart';
import 'package:jarvis_app/src/features/conversations/message_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('没选档位时请求体与改造前逐字相同', () {
    final body = chatMessageBody(
      content: '你好',
      clientMessageId: 'c1',
    );

    expect(body, <String, Object>{'content': '你好', 'client_msg_id': 'c1'});
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  test('选了档位才带上 reasoning_effort，附件照常并列', () {
    final body = chatMessageBody(
      content: '看下这张图',
      clientMessageId: 'c2',
      attachments: const <String>['att_1', 'att_2'],
      reasoningEffort: ReasoningLevels.max,
    );

    expect(body['reasoning_effort'], 'max');
    expect(body['attachments'], <String>['att_1', 'att_2']);
  });

  test('空白档位按"没选"处理：不发空串让服务端去猜', () {
    final body = chatMessageBody(
      content: '',
      clientMessageId: 'c3',
      reasoningEffort: '   ',
    );

    expect(body.containsKey('reasoning_effort'), isFalse);
  });
}
