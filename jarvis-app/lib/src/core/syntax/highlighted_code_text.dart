import 'package:flutter/material.dart';

import '../design/app_palette.dart';
import 'syntax_highlighter.dart';
import 'syntax_language.dart';
import 'syntax_palette.dart';

/// 一行 token → 可绘制的 [TextSpan]。
///
/// 空的 token 行给一个空格：`Text('')` 的行高会塌成 0，整段代码看起来
/// 像被抽掉了空行（与文本预览原来的处理一致）。
TextSpan syntaxLineSpan(
  List<SyntaxToken> tokens,
  TextStyle base,
  AppSyntaxColors colors,
) {
  if (tokens.isEmpty) {
    return TextSpan(text: ' ', style: base);
  }
  final children = <TextSpan>[];
  for (final token in tokens) {
    final style = syntaxTextStyleOf(token.scope, colors);
    children.add(
      style == null
          ? TextSpan(text: token.text)
          : TextSpan(text: token.text, style: style),
    );
  }
  return TextSpan(style: base, children: children);
}

/// 一整块代码的高亮正文（聊天回答里的代码块）。
///
/// 与文件预览共用 [highlightSync]：同一份 scope 映射、同一套配色，
/// 不会出现"聊天里关键字是紫的、预览里是蓝的"。
///
/// 结果按 `(code, language)` 缓存：`build` 会因为父级滚动、主题切换
/// 反复触发，每次都重跑正则会让长回答掉帧。
class HighlightedCodeText extends StatefulWidget {
  const HighlightedCodeText({
    super.key,
    required this.code,
    required this.language,
    required this.style,
  });

  final String code;

  /// `null` 表示没写语言（或语言不认识）：按纯文本显示。
  final SyntaxLanguage? language;

  /// 等宽正文字体。颜色由语法配色决定，这里只提供字号 / 行高 / 字体族。
  final TextStyle style;

  @override
  State<HighlightedCodeText> createState() => _HighlightedCodeTextState();
}

class _HighlightedCodeTextState extends State<HighlightedCodeText> {
  late HighlightedDocument _document;
  AppSyntaxColors? _colors;
  TextSpan? _span;

  @override
  void initState() {
    super.initState();
    _document = highlightSync(widget.code, widget.language);
  }

  @override
  void didUpdateWidget(HighlightedCodeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.language != widget.language) {
      _document = highlightSync(widget.code, widget.language);
      _span = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppPalette.of(context).syntax;
    final cached = _span;
    if (cached == null || _colors != colors) {
      _colors = colors;
      _span = _buildSpan(colors);
    }

    return SelectableText.rich(_span!, style: widget.style);
  }

  TextSpan _buildSpan(AppSyntaxColors colors) {
    final lines = _document.lines;
    final children = <TextSpan>[];
    for (var i = 0; i < lines.length; i++) {
      children.add(syntaxLineSpan(lines[i], widget.style, colors));
      // 行间显式补换行：最后一行后面不补，否则复制出来会多一个空行。
      if (i != lines.length - 1) {
        children.add(const TextSpan(text: '\n'));
      }
    }
    return TextSpan(style: widget.style, children: children);
  }
}
