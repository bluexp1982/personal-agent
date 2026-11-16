import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/syntax/syntax_highlighter.dart';
import 'package:jarvis_app/src/core/syntax/syntax_language.dart';
import 'package:jarvis_app/src/core/syntax/syntax_palette.dart';

void main() {
  final dart = syntaxLanguageOfAlias('dart');

  test('Dart 代码被切出关键字、字符串与数字', () {
    final document = highlightSync(
      'final name = "jarvis";\nfinal count = 42;\n',
      dart,
    );

    expect(document.highlighted, isTrue);
    final scopes = document.lines
        .expand((line) => line)
        .map((token) => token.scope)
        .whereType<String>()
        .toList();
    expect(scopes, contains('keyword'));
    expect(scopes.any((scope) => scope.startsWith('string')), isTrue);
    expect(scopes, contains('number'));
  });

  test('行数与 split 一致：空行与末尾换行都保留', () {
    const code = 'a\n\nb\n';
    final document = highlightSync(code, dart);

    expect(document.lines.length, code.split('\n').length);
    expect(document.lines[1], isEmpty, reason: '第二行是空行');
  });

  test('未知语言按纯文本返回，行数不变', () {
    final document = highlightSync('a\nb', null);

    expect(document.highlighted, isFalse);
    expect(document.lines.length, 2);
    expect(document.lines.first.single.text, 'a');
    expect(document.lines.first.single.scope, isNull);
  });

  test('超过同步阈值不做高亮，但内容仍完整', () {
    final code = 'a' * (kHighlightSyncMaxChars + 1);
    final document = highlightSync(code, dart);

    expect(document.highlighted, isFalse);
    expect(document.lines.length, 1);
    expect(document.lines.first.single.text.length, code.length);
  });

  test('跨行字符串不把 scope 泄漏到下一行之外', () {
    const code = 'const s = """\nline\n""";\nconst next = 1;\n';
    final document = highlightSync(code, dart);

    expect(document.lines.length, code.split('\n').length);
    // 第二行仍在多行字符串里。
    expect(
      document.lines[1].any(
        (token) => token.scope?.startsWith('string') ?? false,
      ),
      isTrue,
    );
    // 第四行已经出了字符串，`1` 应当是数字而不是字符串。
    expect(document.lines[3].any((token) => token.scope == 'number'), isTrue);
  });

  test('后台高亮与同步结果一致（isolate 能拿到语言与文本）', () async {
    const code = 'import "dart:io";\nvoid main() {}\n';
    final sync = highlightSync(code, dart);
    final background = await highlightInBackground(code, dart);

    expect(background.highlighted, isTrue);
    expect(background.lines.length, sync.lines.length);
    for (var i = 0; i < sync.lines.length; i++) {
      expect(
        background.lines[i].map((token) => token.text).join(),
        sync.lines[i].map((token) => token.text).join(),
        reason: '第 ${i + 1} 行文本不一致',
      );
    }
  });

  test('scope 收敛到十一类语义槽', () {
    expect(syntaxKindOfScope('keyword'), SyntaxTokenKind.keyword);
    expect(syntaxKindOfScope('title.function_'), SyntaxTokenKind.function);
    expect(syntaxKindOfScope('title.class.inherited'), SyntaxTokenKind.type);
    expect(syntaxKindOfScope('string.regexp'), SyntaxTokenKind.string);
    expect(syntaxKindOfScope('variable.language'), SyntaxTokenKind.keyword);
    expect(syntaxKindOfScope('meta.preprocessor'), SyntaxTokenKind.meta);
    expect(syntaxKindOfScope('selector-tag'), SyntaxTokenKind.keyword);
    expect(syntaxKindOfScope('completely.unknown'), isNull);
    expect(syntaxKindOfScope(null), isNull);
  });

  test('Vue 单文件组件：template / script / style 内部都有 scope', () {
    const code =
        '<template>\n'
        '  <div class="app">{{ count }}</div>\n'
        '</template>\n'
        '<script>\n'
        'const count = 1;\n'
        '</script>\n'
        '<style>\n'
        '.app { color: red; }\n'
        '</style>\n';

    final document = highlightSync(code, syntaxLanguageOfAlias('vue'));
    final scopes = document.lines
        .expand((line) => line)
        .map((token) => token.scope)
        .whereType<String>()
        .toList();

    expect(document.highlighted, isTrue);
    // xml：`<div>` 是 tag。
    expect(scopes, contains('tag'));
    // javascript：`const` 是关键字。
    expect(scopes, contains('keyword'));
    // css：`color` 是属性。
    expect(
      scopes.any((scope) => scope.startsWith('attribute')),
      isTrue,
      reason: 'Vue 的 <style> 交给 css 子语言处理',
    );
  });

  test('Vue 3 的 <script setup> 也能着色', () {
    const code =
        '<template>\n'
        '  <div />\n'
        '</template>\n'
        '<script setup lang="ts">\n'
        'const count = ref(0);\n'
        '</script>\n';

    final document = highlightSync(code, syntaxLanguageOfAlias('vue'));
    final scopes = document.lines
        .expand((line) => line)
        .map((token) => token.scope)
        .whereType<String>()
        .toList();

    expect(scopes, contains('keyword'));
    expect(
      scopes.any((scope) => scope.startsWith('title.function')),
      isTrue,
      reason: '`ref(...)` 应当被识别成函数调用',
    );
  });

  test('HTML 的 <script> 与 <style> 也按子语言着色', () {
    const code =
        '<html>\n'
        '<style>\n'
        '.app { color: red; }\n'
        '</style>\n'
        '<script>\n'
        'const a = 1;\n'
        '</script>\n'
        '</html>\n';

    final document = highlightSync(code, syntaxLanguageOfAlias('html'));
    final scopes = document.lines
        .expand((line) => line)
        .map((token) => token.scope)
        .whereType<String>()
        .toList();

    expect(scopes, contains('tag'));
    expect(scopes, contains('keyword'));
    expect(scopes.any((scope) => scope.startsWith('attribute')), isTrue);
  });
}
