import 'package:flutter/material.dart';

import '../design/app_palette.dart';

/// 语法 token 的语义分类。
///
/// 只收十一类，与 [AppSyntaxColors] 一一对应：`re_highlight` 的 scope
/// 有上百个（`string.regexp` / `meta.preprocessor` / `title.class.inherited`），
/// 逐个配色既配不完，也会让同一类语义在不同语言里出现不同颜色。
enum SyntaxTokenKind {
  keyword,
  string,
  number,
  comment,
  function,
  type,
  variable,
  property,
  operator,
  meta,
  invalid,
}

/// 完整 scope 的精确匹配。
///
/// 放在首段回退之前：`title.function_` 首段是 `title`，不先接住的话
/// 函数名会被染成"标题"色（在 Markdown 里是另一套观感）。
const Map<String, SyntaxTokenKind> _exactScope = <String, SyntaxTokenKind>{
  'addition': SyntaxTokenKind.string,
  'attribute': SyntaxTokenKind.property,
  'built_in': SyntaxTokenKind.type,
  'deletion': SyntaxTokenKind.invalid,
  'doctag': SyntaxTokenKind.meta,
  'meta.keyword': SyntaxTokenKind.meta,
  'meta.preprocessor': SyntaxTokenKind.meta,
  'meta.string': SyntaxTokenKind.string,
  'params': SyntaxTokenKind.variable,
  'section': SyntaxTokenKind.meta,
  'string.regexp': SyntaxTokenKind.string,
  'title.class': SyntaxTokenKind.type,
  'title.class.inherited': SyntaxTokenKind.type,
  'title.function': SyntaxTokenKind.function,
  'title.function.invoke': SyntaxTokenKind.function,
  'title.function_': SyntaxTokenKind.function,
  'variable.constant': SyntaxTokenKind.number,
  'variable.language': SyntaxTokenKind.keyword,
};

/// 首段回退：命中不了的 scope 用正文色，不会出现"没着色"的洞。
const Map<String, SyntaxTokenKind> _headScope = <String, SyntaxTokenKind>{
  'attr': SyntaxTokenKind.property,
  'bullet': SyntaxTokenKind.meta,
  'char': SyntaxTokenKind.string,
  'class': SyntaxTokenKind.type,
  'comment': SyntaxTokenKind.comment,
  'function': SyntaxTokenKind.function,
  'keyword': SyntaxTokenKind.keyword,
  'link': SyntaxTokenKind.function,
  'literal': SyntaxTokenKind.number,
  'meta': SyntaxTokenKind.meta,
  'name': SyntaxTokenKind.property,
  'number': SyntaxTokenKind.number,
  'operator': SyntaxTokenKind.operator,
  'property': SyntaxTokenKind.property,
  'punctuation': SyntaxTokenKind.operator,
  'quote': SyntaxTokenKind.comment,
  'regexp': SyntaxTokenKind.string,
  'selector-attr': SyntaxTokenKind.property,
  'selector-class': SyntaxTokenKind.type,
  'selector-id': SyntaxTokenKind.function,
  'selector-pseudo': SyntaxTokenKind.meta,
  'selector-tag': SyntaxTokenKind.keyword,
  'string': SyntaxTokenKind.string,
  'symbol': SyntaxTokenKind.meta,
  'tag': SyntaxTokenKind.meta,
  'title': SyntaxTokenKind.function,
  'type': SyntaxTokenKind.type,
  'variable': SyntaxTokenKind.variable,
};

/// scope → 语义分类。多个 class 时只看第一个。
SyntaxTokenKind? syntaxKindOfScope(String? scope) {
  if (scope == null) {
    return null;
  }
  // `re_highlight` 的 multi-class 插件会给出 `"keyword"`、`"title function_"`
  // 这类空格分隔的组合；取第一个非空项。
  final first = scope
      .split(' ')
      .firstWhere((part) => part.isNotEmpty, orElse: () => '');
  if (first.isEmpty) {
    return null;
  }

  final exact = _exactScope[first];
  if (exact != null) {
    return exact;
  }

  final dot = first.indexOf('.');
  return _headScope[dot < 0 ? first : first.substring(0, dot)];
}

/// 语义分类 → 当前主题的文字色。
Color? syntaxColorOf(SyntaxTokenKind? kind, AppSyntaxColors colors) {
  return switch (kind) {
    null => null,
    SyntaxTokenKind.keyword => colors.keyword,
    SyntaxTokenKind.string => colors.string,
    SyntaxTokenKind.number => colors.number,
    SyntaxTokenKind.comment => colors.comment,
    SyntaxTokenKind.function => colors.function,
    SyntaxTokenKind.type => colors.type,
    SyntaxTokenKind.variable => colors.variable,
    SyntaxTokenKind.property => colors.property,
    SyntaxTokenKind.operator => colors.operator,
    SyntaxTokenKind.meta => colors.meta,
    SyntaxTokenKind.invalid => colors.invalid,
  };
}

/// 给一段 token 配的文字样式；`null` 表示沿用正文样式。
///
/// 只改颜色，不碰字号/字重/行高：这些由调用方（代码视图）决定，
/// 语义层越权会让同一份 token 在聊天与预览里长得不一样。
TextStyle? syntaxTextStyleOf(String? scope, AppSyntaxColors colors) {
  final color = syntaxColorOf(syntaxKindOfScope(scope), colors);
  return color == null ? null : TextStyle(color: color);
}
