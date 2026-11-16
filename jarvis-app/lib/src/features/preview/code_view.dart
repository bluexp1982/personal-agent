import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/syntax/highlighted_code_text.dart';
import '../../core/syntax/syntax_highlighter.dart';
import '../../core/syntax/syntax_language.dart';
import '../shell/file_preview_menu.dart';
import '../shell/shell_layout_state.dart';

/// 带行号与语法高亮的代码正文。
///
/// 与 [MarkdownPreviewView] 的源码模式、普通文本预览共用：三处都只是
/// "把一段字符串按行画出来"，各写一份必然出现行号宽度、空行行高、
/// 右键菜单的漂移。
///
/// 高亮结果在组件内部异步计算并缓存；首帧先画纯文本，避免大文件打开时
/// 先白一屏。滚动位置由 [storageKey] 交给 `PageStorage`，进出全屏、
/// 切换预览/源码回来后不会回到顶部。
class CodeView extends StatefulWidget {
  const CodeView({
    super.key,
    required this.text,
    required this.language,
    this.storageKey,
  });

  final String text;

  /// `null` 表示未知语言：仍按等宽正文渲染，只是不上色。
  final SyntaxLanguage? language;

  /// 同一个文件的不同视图（源码 / Markdown 渲染）要给不同的 key，
  /// 否则两个视图会共享同一个滚动位置。
  final String? storageKey;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  HighlightedDocument? _document;

  /// 纯文本兜底：高亮还没回来（或不需要高亮）时按行画。
  ///
  /// 在 initState / 切文件时算一次并存下来——放在 build 里算的话，
  /// 每一帧滚动都会把整份文件 `split('\n')` 一遍，512 KB 的文件直接掉帧。
  late HighlightedDocument _plain;

  /// 丢弃过期结果：切文件时上一次 isolate 可能后回来。
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _plain = highlightSync(widget.text, null);
    _load();
  }

  @override
  void didUpdateWidget(CodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.language != widget.language) {
      _plain = highlightSync(widget.text, null);
      _load();
    }
  }

  void _load() {
    final token = ++_loadToken;

    // 小文件同步算完：isolate 的调度开销比高亮本身还大，
    // 而且同步能保证第一帧就是着色后的样子，不会闪一下白字。
    if (widget.text.length <= kHighlightSyncMaxChars) {
      _document = highlightSync(widget.text, widget.language);
      return;
    }

    _document = null;
    highlightInBackground(widget.text, widget.language).then((document) {
      if (!mounted || token != _loadToken) {
        return;
      }
      setState(() => _document = document);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // 与正文同字号同字体：行号与代码的基线自然对齐，不用再调行高。
    final lineStyle = AppText.of(context)
        .mono(size: AppFontSize.sm, height: AppLineHeight.normal);
    final numberStyle = lineStyle.copyWith(color: palette.text.disabled);

    // 高亮还没回来时按纯文本画：行数、行号、选中复制都照常可用。
    final lines = (_document ?? _plain).lines;
    final gutter = _numberGutter(context, lines.length, numberStyle);

    return SelectionArea(
      // 默认实现是系统文本工具条（未配中文时是英文 Copy / Select All），
      // 与全站菜单不是一套外观；这里换成项目统一的 AgentMenuPanel。
      contextMenuBuilder: (context, state) =>
          FilePreviewContextMenu(state: state),
      child: ListView.builder(
        key: PageStorageKey<String>(widget.storageKey ?? 'code-view'),
        padding: const EdgeInsets.fromLTRB(
          kPaneEdgeInset,
          8,
          kPaneContentInset,
          18,
        ),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          return Row(
            // 折行时行号停在第一行顶端，和编辑器里的观感一致。
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 行号必须禁用选择：否则「全选 + 复制」会把一列数字一起带走。
              SelectionContainer.disabled(
                child: SizedBox(
                  width: gutter,
                  child: Text(
                    '${index + 1}',
                    maxLines: 1,
                    textAlign: TextAlign.right,
                    style: numberStyle,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  syntaxLineSpan(lines[index], lineStyle, palette.syntax),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 行号列宽：按"最大行号的位数"量一次数字宽度。
  ///
  /// 只量数字，不逐行量正文——后者要布局整份文件，会破坏 `ListView` 的懒布局，
  /// 大文件打开时明显卡顿。
  double _numberGutter(BuildContext context, int lineCount, TextStyle style) {
    final digits = '$lineCount'.length;
    final painter = TextPainter(
      text: TextSpan(text: '9' * digits, style: style),
      textDirection: TextDirection.ltr,
      // 跟随系统文字缩放，否则大字号下数字会被列宽裁掉。
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width.ceilToDouble();
  }
}
