import 'package:jarvis_app/src/features/conversations/message_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('加粗与行内代码被解析，字面符号不再露出', (tester) async {
    await tester.pumpWidget(
      _wrap(const MessageMarkdown(data: '这里是 **重点** 和 `code`。')),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('重点', findRichText: true), findsWidgets);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('`', findRichText: true), findsNothing);
  });

  testWidgets('围栏代码块保留原文并带横向滚动容器', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MessageMarkdown(data: '示例：\n\n```python\nprint("hi")\n```\n'),
      ),
    );

    expect(
      find.textContaining('print("hi")', findRichText: true),
      findsWidgets,
    );
    expect(find.textContaining('```', findRichText: true), findsNothing);
    // 长行靠横向滚动而不是折行，缩进层级不会被折行打乱。
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('代码块是浅底无边框，左上角标语言、右上角可复制', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(
            (call.arguments as Map<dynamic, dynamic>)['text'] as String,
          );
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      _wrap(
        const MessageMarkdown(
          data: '```python\nprint("hi")\nprint("bye")\n```\n',
        ),
      ),
    );

    expect(find.byType(MessageCodeBlock), findsOneWidget);
    expect(find.text('python'), findsOneWidget);

    // 浅灰底（参考图采样后再压深一档），且要和用户气泡的 #EDF3FE 分得开。
    final block = tester.widget<MessageCodeBlock>(
      find.byType(MessageCodeBlock),
    );
    expect(block.palette.codeBackground, const Color(0xFFF3F4F6));
    expect(
      block.palette.codeBackground,
      isNot(block.palette.userBubble),
      reason: '代码块底色必须与用户气泡区分开',
    );
    final decorations = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('python'),
            matching: find.byType(Container),
          ),
        )
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.color != null);
    expect(decorations.first.color, const Color(0xFFF3F4F6));
    expect(decorations.first.border, isNull);

    // 复制的是代码原文：不含语言标识，末尾也不带围栏留下的空行。
    await tester.tap(find.byTooltip('复制'));
    await tester.pump();
    expect(copied, <String>['print("hi")\nprint("bye")']);
    expect(find.text('已复制'), findsOneWidget);

    // 让对勾复位与提示条的定时器跑完。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('代码块没写语言时左上角回落 text', (tester) async {
    await tester.pumpWidget(
      _wrap(const MessageMarkdown(data: '```\nplain\n```\n')),
    );

    expect(find.text('text'), findsOneWidget);
  });

  testWidgets('暗色主题下代码块底色跟着换', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: MessageMarkdown(data: '```tsx\nconst a = 1;\n```\n'),
        ),
      ),
    );

    final block = tester.widget<MessageCodeBlock>(
      find.byType(MessageCodeBlock),
    );
    expect(block.palette.codeBackground, const Color(0xFF24272D));
    expect(
      block.palette.codeBackground,
      isNot(block.palette.userBubble),
      reason: '暗色下两种底色同样要分开',
    );
    expect(find.text('tsx'), findsOneWidget);
  });

  testWidgets('标题与列表渲染成富文本，不露出井号与星号', (tester) async {
    await tester.pumpWidget(
      _wrap(const MessageMarkdown(data: '# 标题\n\n- 第一项\n- 第二项\n')),
    );

    expect(find.textContaining('标题', findRichText: true), findsWidgets);
    expect(find.textContaining('第一项', findRichText: true), findsWidgets);
    expect(find.textContaining('#', findRichText: true), findsNothing);
  });

  testWidgets('点击链接复制地址并提示，不拉起外部程序', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<dynamic, dynamic>;
          copied.add(args['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      _wrap(const MessageMarkdown(data: '看[文档](https://example.com/doc)。')),
    );

    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.onTapLink, isNotNull);

    body.onTapLink!('文档', 'https://example.com/doc', '');
    await tester.pumpAndSettle();

    expect(copied, <String>['https://example.com/doc']);
    expect(find.text('链接已复制'), findsOneWidget);
  });
}
