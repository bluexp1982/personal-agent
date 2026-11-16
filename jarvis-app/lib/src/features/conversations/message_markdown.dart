import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/design/message_palette.dart';
import '../../core/syntax/highlighted_code_text.dart';
import '../../core/syntax/syntax_language.dart';
import 'message_copy_button.dart';

// Markdown 的排版行高不属于 UI 行高体系：正文按中文长段落取 1.55，
// 标题按层级收紧到 1.35 / 1.4。收成具名常量是为了让"为什么不是 1.5"
// 有地方可查，而不是散在几个 copyWith 里当魔术数字。
const double _mdBodyHeight = 1.55;
const double _mdHeadingHeight = 1.35;
const double _mdSubheadingHeight = 1.4;

/// 回答正文的 Markdown 渲染。
///
/// 只有 AI 回答走这里；用户自己发的话仍按纯文本显示——用户输入里的
/// ``` 与 `*` 是原话的一部分，不该被当成排版指令。
///
/// 样式全部按气泡内的窄容器收敛：默认主题的 h1 有 24pt、段落间距 16，
/// 直接套进 620dp 的气泡会把一段短回答撑成一屏。代码块由自定义 builder
/// 整块接管（见 [MessageCodeBlock]），这里只负责其余元素的排版。
class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context).message;

    return MarkdownBody(
      data: data,
      selectable: true,
      // 模型常拿单个换行分点；按 GFM 合并成空格会挤成一整段。
      softLineBreak: true,
      styleSheet: _styleSheet(context),
      builders: <String, MarkdownElementBuilder>{
        'pre': _CodeBlockBuilder(
          palette: palette,
          monoStyle: _monoStyle(context),
          labelStyle: _languageStyle(context, palette),
        ),
      },
      onTapLink: (text, href, title) => _copyLink(context, href),
    );
  }

  /// 不申请打开浏览器：桌面端拉起外部程序要额外依赖与权限，
  /// 这里与来源卡片保持一致——复制链接、给一句提示。
  Future<void> _copyLink(BuildContext context, String? href) async {
    if (href == null || href.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: href));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('链接已复制'), duration: Duration(seconds: 2)),
    );
  }

  /// 等宽字体样式：代码块与行内代码共用，观感才不会一处分叉一处不分叉。
  ///
  /// 三个桌面端至少要命中一个：macOS 认 Menlo，Windows 认 Consolas，
  /// Linux 兜底到 fontconfig 的 monospace。
  TextStyle? _monoStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodyMedium?.copyWith(
      height: AppLineHeight.code,
      fontSize: AppFontSize.md,
      color: AppPalette.of(context).text.primary,
      fontFamily: AppMono.family,
      fontFamilyFallback: AppMono.fallback,
    );
  }

  /// 代码块左上角的语言标识：小号灰字，压在手写代码的光环之下。
  TextStyle? _languageStyle(BuildContext context, MessagePalette palette) {
    return Theme.of(context).textTheme.labelSmall?.copyWith(
      fontSize: AppFontSize.sm,
      height: AppLineHeight.tight,
      letterSpacing: AppLetterSpacing.tight,
      color: palette.meta,
    );
  }

  MarkdownStyleSheet _styleSheet(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodyMedium;
    final body = base?.copyWith(
      fontSize: AppFontSize.base,
      color: scheme.onSurface,
      height: _mdBodyHeight,
    );
    final mono = _monoStyle(context);

    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      pPadding: const EdgeInsets.only(top: 2, bottom: 2),
      blockSpacing: 8,
      a: body?.copyWith(
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary.withValues(alpha: 0.5),
      ),
      em: body?.copyWith(fontStyle: FontStyle.italic),
      strong: body?.copyWith(fontWeight: AppWeight.semiBold),
      del: body?.copyWith(decoration: TextDecoration.lineThrough),
      h1: body?.copyWith(
        fontSize: AppFontSize.h1,
        fontWeight: AppWeight.semiBold,
        height: _mdHeadingHeight,
      ),
      h1Padding: const EdgeInsets.only(top: 6, bottom: 2),
      h2: body?.copyWith(
        fontSize: AppFontSize.h2,
        fontWeight: AppWeight.semiBold,
        height: _mdHeadingHeight,
      ),
      h2Padding: const EdgeInsets.only(top: 6, bottom: 2),
      h3: body?.copyWith(
        fontSize: AppFontSize.h3,
        fontWeight: AppWeight.semiBold,
        height: _mdSubheadingHeight,
      ),
      h3Padding: const EdgeInsets.only(top: 4, bottom: 2),
      h4: body?.copyWith(fontWeight: AppWeight.semiBold),
      h4Padding: const EdgeInsets.only(top: 4),
      h5: body?.copyWith(fontWeight: AppWeight.semiBold),
      h6: body?.copyWith(fontWeight: AppWeight.semiBold),
      // 行内代码保持无底色：句子里的 `print` 加底块会碎成一地色斑。
      code: mono?.copyWith(color: scheme.onSurface),
      // 代码块的底色与内边距由 MessageCodeBlock 自己画，这里必须留空装饰：
      // 组件在处理完自定义 builder 之后仍会拿它包一层 Container，
      // 留着默认的 surface + 描边就会出现"块里再套一个块"。
      codeblockDecoration: const BoxDecoration(),
      blockquote: body?.copyWith(color: scheme.onSurfaceVariant),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          left: BorderSide(color: scheme.outlineVariant, width: 3),
        ),
      ),
      listBullet: body,
      listBulletPadding: const EdgeInsets.only(right: 4),
      listIndent: 20,
      tableHead: body?.copyWith(
        fontSize: AppFontSize.md,
        fontWeight: AppWeight.semiBold,
      ),
      tableBody: body?.copyWith(fontSize: AppFontSize.md),
      tableBorder: TableBorder.all(color: scheme.outlineVariant),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      // 宽度按内容取，宽表才会触发组件内置的横向滚动而不是把列压扁。
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableScrollbarThumbVisibility: false,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
    );
  }
}

/// 把栅栏代码块整块换成"浅底 + 表头"的样子。
///
/// `pre` 在 flutter_markdown 里是块级元素，注册 builder 后组件会直接用
/// 返回的 widget 替换默认渲染（默认路径是 surface 底 + 描边 + 横向滚动）。
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({
    required this.palette,
    required this.monoStyle,
    required this.labelStyle,
  });

  final MessagePalette palette;
  final TextStyle? monoStyle;
  final TextStyle? labelStyle;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return MessageCodeBlock(
      code: codeBlockText(element),
      language: codeBlockLanguage(element),
      palette: palette,
      monoStyle: monoStyle,
      labelStyle: labelStyle,
    );
  }
}

/// 代码块正文：保留内部换行与缩进，只去掉末尾换行。
///
/// 末尾那个 `\n` 是围栏语法自带的，留在正文里会让复制结果多一行空行。
String codeBlockText(md.Element element) {
  return element.textContent.replaceFirst(RegExp(r'\n+$'), '');
}

/// 代码块语言：取 `pre > code` 的 `class="language-xxx"`。
///
/// 没写语言时固定回落 `text`：表头永远存在，复制按钮就不会因缺语言而左右跳。
String codeBlockLanguage(md.Element element) {
  for (final child in element.children ?? const <md.Node>[]) {
    if (child is! md.Element || child.tag != 'code') {
      continue;
    }
    final className = child.attributes['class'] ?? '';
    const prefix = 'language-';
    if (className.startsWith(prefix)) {
      final name = className.substring(prefix.length).trim();
      if (name.isNotEmpty) {
        return name;
      }
    }
  }
  return 'text';
}

/// 代码块：整块浅色圆角底（无描边）+ 表头（语言 / 复制）+ 可横向滚动的正文。
///
/// 底色走 [MessagePalette.codeBackground]（中性浅灰），与用户气泡的蓝调分开，
/// 一眼能分辨"我发的话"和"引用的代码"；正文用等宽字体，长行靠横向滚动而不是
/// 折行，免得缩进层级被打乱。
class MessageCodeBlock extends StatelessWidget {
  const MessageCodeBlock({
    super.key,
    required this.code,
    required this.language,
    required this.palette,
    required this.monoStyle,
    required this.labelStyle,
  });

  final String code;
  final String language;
  final MessagePalette palette;
  final TextStyle? monoStyle;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.codeBackground,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ),
                MessageCopyButton(text: code),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
            // 与文件预览共用同一套高亮与配色：同一个模型回答里的
            // `keyword` 在右栏预览里是紫的，在这里也该是紫的。
            // 语言标签不认识时 `language` 为 null，组件按纯文本渲染，
            // 不会因为 `language-foo` 这种随手写的标签而报错。
            child: HighlightedCodeText(
              code: code,
              language: syntaxLanguageOfAlias(language),
              style:
                  monoStyle ??
                  AppText.of(
                    context,
                  ).mono(size: AppFontSize.md, height: AppLineHeight.code),
            ),
          ),
        ],
      ),
    );
  }
}
