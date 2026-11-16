import 'package:jarvis_app/src/core/session.dart';
import 'package:jarvis_app/src/features/conversations/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 中文输入法组字期间的 Enter 归输入法，不能当发送。
///
/// 真机上的时序测试复现不了（macOS 可能先把候选上屏、再把同一次按键派给
/// 框架），所以这里直接驱动两次 `updateEditingValue` 的状态：
/// composing 非空 = 正在组字；composing 清空 = 刚上屏。

class _Harness {
  _Harness(this.controller);

  final QuillController controller;
  int sent = 0;

  String get plainText => controller.document.toPlainText();
}

Future<_Harness> _pump(WidgetTester tester) async {
  final controller = QuillController.basic();
  addTearDown(controller.dispose);
  final harness = _Harness(controller);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(null)],
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              ChatComposer(
                controller: controller,
                sending: false,
                onSend: () => harness.sent += 1,
                onStop: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 按键是从编辑器往下派的，先让它拿到焦点并建立输入连接。
  await tester.tap(find.byType(QuillEditor));
  await tester.pump();

  return harness;
}

/// 输入法把一段拼音放进编辑器：整段都是组字区间（带下划线那部分）。
///
/// 文本末尾带 `\n`：quill 的文档永远以换行块结尾，给平台的值也照这个形状，
/// 否则它按 diff 做替换时会越界（真实输入法看到的就是带换行的值）。
Future<void> _compose(WidgetTester tester, String pinyin) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '$pinyin\n',
      selection: TextSelection.collapsed(offset: pinyin.length),
      composing: TextRange(start: 0, end: pinyin.length),
    ),
  );
  await tester.pump();
}

/// 输入法把候选替换成汉字：组字结束，文本已上屏。
Future<void> _commit(WidgetTester tester, String text) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '$text\n',
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('组字中按 Enter：不认领按键、不发送、不换行', (tester) async {
    final harness = await _pump(tester);
    await _compose(tester, 'shafa');
    final before = harness.plainText;

    // 返回值是"框架是否认领这次按键"。组字中必须为 false：
    // 认领了（handled）键盘就不会回传给平台，输入法再也收不到回车，
    // 候选词选不了——这正是上一版的 bug。
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(handled, isFalse, reason: '回车要回到平台交给输入法，框架不能认领');
    expect(harness.sent, 0, reason: '组字中的 Enter 是选词/上屏，不该发送');
    expect(harness.plainText, before, reason: '也不能让编辑器把换行插进拼音串里');

    // 收尾时把组字区间清掉：quill 11.6 的 `dispose` 里改这个值会触发
    // setState-after-dispose 断言，组字状态留到卸载就会在收尾时炸。
    await _commit(tester, 'shafa');
  });

  testWidgets('组字中按 Shift+Enter 也不认领、不换行', (tester) async {
    final harness = await _pump(tester);
    await _compose(tester, 'shafa');
    final before = harness.plainText;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(handled, isFalse, reason: '组字中的回车统一交给输入法');
    expect(harness.plainText, before, reason: '组字中的换行会把拼音串切断');

    await _commit(tester, 'shafa');
  });

  testWidgets('上屏那一下 Enter 被吞掉不发送，紧接着的 Enter 才发送', (tester) async {
    final harness = await _pump(tester);
    await _compose(tester, 'shafa');
    await _commit(tester, '沙发');

    // 这一下输入法已经完成上屏，不必再回传平台，否则可能再插一个换行。
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pump();

    expect(harness.sent, 0, reason: '这一下 Enter 属于上屏，不是发送');
    expect(harness.plainText, contains('沙发'));

    await tester.pump(const Duration(milliseconds: 400));
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pump();

    expect(harness.sent, 1);
  });

  testWidgets('组字中吞下的 Enter 不会连带吞掉上屏后的发送', (tester) async {
    final harness = await _pump(tester);
    await _compose(tester, 'shafa');

    // 先按键、后上屏：这一下交给输入法，框架不认领。
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
    await tester.pump();
    expect(harness.sent, 0);

    await _commit(tester, '沙发');

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pump();

    expect(harness.sent, 1, reason: '上屏已经发生，这一次 Enter 就是用户要发送');
  });

  testWidgets('没有组字时 Enter 照常发送', (tester) async {
    final harness = await _pump(tester);
    harness.controller.replaceText(
      0,
      0,
      'hi',
      const TextSelection.collapsed(offset: 2),
    );
    await tester.pump();

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
    await tester.pump();

    expect(harness.sent, 1);
  });
}
