import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:re_highlight/re_highlight.dart';

import 'syntax_language.dart';

/// 超过这个体量不做高亮：正则驱动的语法分析是 O(字符数)，200 KB 之后
/// 单次耗时已经越过一帧的预算，而这么大的文件本来也读不完。
const int kHighlightMaxChars = 200 * 1024;

/// 行数上限。与字符数上限取"先到先算"：一屏代码行短、行数多时，
/// 只按字符数判断会放出几万行，`ListView` 的 itemBuilder 再快也画不完。
const int kHighlightMaxLines = 4000;

/// 同步路径的上限（聊天代码块走这里）：超过一帧能承受的体量就退回纯文本，
/// 绝不把一个可能几百毫秒的正则挂在 UI 线程上。
const int kHighlightSyncMaxChars = 16 * 1024;

/// 高亮结果里的一段文字。
///
/// 刻意用纯数据（两个 String）而不是 [TextSpan]：跨 isolate 传递时
/// `TextSpan` 的 paint 相关字段不可 send，而这里只需要"文字 + 语义"。
/// [scope] 为 `null` 表示正文（关键字之外的空格、标点）。
@immutable
class SyntaxToken {
  const SyntaxToken(this.text, this.scope);

  final String text;

  /// highlight.js 的 scope，如 `keyword`、`title.function_`。
  final String? scope;

  @override
  bool operator ==(Object other) =>
      other is SyntaxToken && other.text == text && other.scope == scope;

  @override
  int get hashCode => Object.hash(text, scope);

  @override
  String toString() => 'SyntaxToken(${scope ?? 'text'}: $text)';
}

/// 一份按行切好的高亮文档。
///
/// `lines.length` 与 `code.split('\n').length` 恒等：行号列直接按索引画，
/// 不需要再对齐一次。
@immutable
class HighlightedDocument {
  const HighlightedDocument({required this.lines, required this.highlighted});

  final List<List<SyntaxToken>> lines;

  /// `false` 表示这份内容是纯文本（未知语言、超过阈值或高亮失败）。
  /// 界面据此决定是否显示"已关闭高亮"的提示。
  final bool highlighted;
}

/// 聊天代码块这类小片段：同步高亮，拿不到就退回纯文本。
HighlightedDocument highlightSync(String code, SyntaxLanguage? language) {
  if (language == null || !_shouldHighlight(code, kHighlightSyncMaxChars)) {
    return _plainDocument(code);
  }
  try {
    return HighlightedDocument(
      lines: _highlightLinesSync(code, language),
      highlighted: true,
    );
  } catch (_) {
    // 语法定义的边界情况很多（未闭合字符串、非 UTF-16 代理对），
    // 预览不该因为一份文件里的一行怪字符整页报错。
    return _plainDocument(code);
  }
}

/// 文件预览：放到后台 isolate，避免长文件把首帧卡住。
Future<HighlightedDocument> highlightInBackground(
  String code,
  SyntaxLanguage? language,
) async {
  if (language == null || !_shouldHighlight(code, kHighlightMaxChars)) {
    return _plainDocument(code);
  }

  // Web 没有 isolate，退回同步：总比直接不给高亮好，且 web 端不是主路径。
  if (kIsWeb) {
    return highlightSync(code, language);
  }

  try {
    final lines = await Isolate.run(() => _highlightLinesSync(code, language));
    return HighlightedDocument(lines: lines, highlighted: true);
  } catch (_) {
    return _plainDocument(code);
  }
}

bool _shouldHighlight(String code, int maxChars) {
  if (code.length > maxChars) {
    return false;
  }
  // 行数只在字符数通过后再数：先数行会在超长的一行上白跑一遍。
  var lines = 1;
  for (var i = 0; i < code.length; i++) {
    if (code.codeUnitAt(i) == 0x0A) {
      lines++;
      if (lines > kHighlightMaxLines) {
        return false;
      }
    }
  }
  return true;
}

/// 在**新**的 `Highlight` 实例上注册语言并跑一遍。
///
/// 每次新建而不是共享单例：`Highlight` 内部保留的是编译后的正则缓存，
/// 跨 isolate 不能共享；同 isolate 内重复构造也只是几十毫秒的语法编译，
/// 而结果本身由 [HighlightedCodeText] 缓存，不会每次 rebuild 都走这里。
List<List<SyntaxToken>> _highlightLinesSync(
  String code,
  SyntaxLanguage language,
) {
  final highlight = Highlight()
    ..registerLanguage(language.id, grammarOf(language));
  // 子语言必须先注册：`processSubLanguage` 找不到目标语言时会把整段
  // 原样 `addText`（不报错），Vue / HTML 这类"外壳语法"就会一个颜色都没有。
  for (final sub in subLanguagesOf(language)) {
    highlight.registerLanguage(sub.id, grammarOf(sub));
  }
  final result = highlight.highlight(code: code, language: language.id);
  final renderer = _LineRenderer();
  result.render(renderer);
  return renderer.lines;
}

HighlightedDocument _plainDocument(String code) {
  final lines = <List<SyntaxToken>>[];
  for (final line in code.split('\n')) {
    lines.add(
      line.isEmpty
          ? const <SyntaxToken>[]
          : <SyntaxToken>[SyntaxToken(line, null)],
    );
  }
  return HighlightedDocument(lines: lines, highlighted: false);
}

/// 把 `HighlightResult` 的节点流切成"行 → token"。
///
/// 不自己遍历 `DataNode` 树：`render(renderer)` 已经按深度优先给出
/// 开/闭节点与文本，跟着走一遍就够了，还能天然处理嵌套 scope
/// （字符串里的转义、heredoc 里的变量）。
class _LineRenderer implements HighlightRenderer {
  final List<List<SyntaxToken>> lines = <List<SyntaxToken>>[<SyntaxToken>[]];
  final List<String?> _scopes = <String?>[];

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) {
    if (_scopes.isNotEmpty) {
      _scopes.removeLast();
    }
  }

  @override
  void addText(String text) {
    if (text.isEmpty) {
      return;
    }
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 0x0A) {
        continue;
      }
      _append(text.substring(start, i));
      lines.add(<SyntaxToken>[]);
      start = i + 1;
    }
    if (start < text.length) {
      _append(text.substring(start));
    }
  }

  void _append(String text) {
    if (text.isEmpty) {
      return;
    }
    final scope = _scopes.isEmpty ? null : _scopes.last;
    final line = lines.last;
    // 相邻同 scope 合并：`if` 后面跟一个空格再跟 `(` 时，三个节点合成一个
    // `TextSpan`，一页少几十个 span，选中复制也不会被切碎。
    if (line.isNotEmpty && line.last.scope == scope) {
      line[line.length - 1] = SyntaxToken(line.last.text + text, scope);
      return;
    }
    line.add(SyntaxToken(text, scope));
  }
}
