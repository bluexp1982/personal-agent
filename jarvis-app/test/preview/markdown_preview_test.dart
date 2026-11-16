import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:jarvis_app/src/core/project_file_providers.dart';
import 'package:jarvis_app/src/core/syntax/syntax_highlighter.dart';
import 'package:jarvis_app/src/core/syntax/syntax_language.dart';
import 'package:jarvis_app/src/features/conversations/message_markdown.dart';
import 'package:jarvis_app/src/features/preview/code_view.dart';
import 'package:jarvis_app/src/features/preview/markdown_preview_view.dart';
import 'package:jarvis_app/src/features/shell/file_preview_view.dart';

const String _path = '/tmp/hello-demo/README.md';

Widget _harness(String text, {bool truncated = false}) {
  return ProviderScope(
    overrides: [
      projectFileContentProvider.overrideWith(
        (ref, key) => FileContent(
          path: key.path,
          size: text.length,
          text: text,
          truncated: truncated,
        ),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 520,
          height: 720,
          child: const MarkdownPreviewView(
            projectId: 'hello-demo',
            path: _path,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('默认渲染文档，不露出 Markdown 标记', (tester) async {
    await tester.pumpWidget(_harness('# 标题\n\n这里是一段 **重点** 文字。\n\n- 一\n- 二\n'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(CodeView), findsNothing);
    expect(find.textContaining('#', findRichText: true), findsNothing);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('重点', findRichText: true), findsWidgets);
  });

  testWidgets('切到源码后显示原文与行号，再切回来恢复渲染', (tester) async {
    await tester.pumpWidget(_harness('# 标题\n\n正文\n'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kMarkdownSourceToggleKey));
    await tester.pumpAndSettle();

    expect(find.byType(CodeView), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
    // 行号列与源码都在：第 1 行是标题原文。
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('# 标题', findRichText: true), findsWidgets);

    await tester.tap(find.byKey(kMarkdownSourceToggleKey));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(CodeView), findsNothing);
  });

  testWidgets('围栏代码块复用 MessageCodeBlock，并带语言标签', (tester) async {
    await tester.pumpWidget(_harness('```dart\nfinal name = "jarvis";\n```\n'));
    await tester.pumpAndSettle();

    expect(find.byType(MessageCodeBlock), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
  });

  testWidgets('超大文档默认进源码模式', (tester) async {
    // 略高于渲染阈值：整篇渲染会明显发顿，默认落到源码。
    // 这里不再点回预览——几十万字符的单段文本会让测试把时间花在
    // 极端排版上，而"能切回预览"已由上面两个用例覆盖同一套状态。
    final text = '# 大文档\n\n${'a' * (200 * 1024 + 1)}';
    await tester.pumpWidget(_harness(text));
    await tester.pumpAndSettle();

    expect(find.byType(CodeView), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
    // 开关仍在：用户想渲染可以自己切，不是一刀切禁掉。
    expect(find.byKey(kMarkdownSourceToggleKey), findsOneWidget);
  });

  testWidgets('文件头具备全屏与另存为，与其它查看器一致', (tester) async {
    await tester.pumpWidget(_harness('# 标题\n'));
    await tester.pumpAndSettle();

    expect(find.byKey(kPreviewFullscreenKey), findsOneWidget);
    expect(find.byKey(kPreviewSaveKey), findsOneWidget);
  });

  testWidgets('截断提示条在文档视图里也显示', (tester) async {
    await tester.pumpWidget(_harness('# 标题\n', truncated: true));
    await tester.pumpAndSettle();

    expect(find.text('文件较大，仅显示前一部分'), findsOneWidget);
  });

  test('源码视图按 Markdown 语法高亮，且不改变行数', () {
    const code = '# 标题\n\n正文\n';
    final document = highlightSync(code, syntaxLanguageOfAlias('markdown'));
    expect(document.highlighted, isTrue);
    expect(document.lines.length, code.split('\n').length);
  });
}
