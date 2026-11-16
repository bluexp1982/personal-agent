import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不接服务端：输入栏的键位行为与网络无关，只要 provider 返回 null 即可。
Widget _harness() {
  return ProviderScope(
    overrides: [apiClientProvider.overrideWithValue(null)],
    child: const MaterialApp(
      home: ChatPage(conversationId: 'c1', title: '会话'),
    ),
  );
}

String _text(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('Shift+Enter 在光标处换行', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump();

    await tester.enterText(find.byType(TextField), '第一行');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(_text(tester), '第一行\n');
  });

  testWidgets('Enter 不是换行：它被当成发送，空客户端下文本保持不变', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump();

    await tester.enterText(find.byType(TextField), '第一行');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(_text(tester), '第一行', reason: 'Enter 应该走发送分支，而不是在输入框里插入换行');
  });
}
