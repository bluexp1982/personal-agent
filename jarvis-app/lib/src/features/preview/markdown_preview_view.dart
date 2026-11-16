import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/project_file_providers.dart';
import '../../core/syntax/syntax_language.dart';
import '../../core/ui/shell_icon_button.dart';
import '../conversations/message_markdown.dart';
import '../shell/file_pane_state.dart';
import '../shell/file_preview_header.dart';
import '../shell/immersive_fullscreen.dart';
import '../shell/shell_layout_state.dart';
import 'code_view.dart';
import 'preview_actions.dart';
import 'preview_states.dart';

/// 超过这个体量就不默认渲染排版：Markdown 的解析与布局都是整篇一次做完，
/// 200 KB 之后首帧会明显发顿，而这么大的文档本来也是源码更好定位。
const int _kMarkdownRenderMaxChars = 200 * 1024;

/// 预览 / 源码切换按钮的稳定锚点。
const Key kMarkdownSourceToggleKey = Key('markdown-source-toggle');

/// Markdown 文件查看器。
///
/// 与普通文本预览的区别只有"默认怎么画"：这里默认渲染排版后的文档，
/// 文件头多一个「预览 / 源码」开关；源码模式复用 [CodeView]，
/// 所以行号、语法高亮、选中复制、右键菜单都与代码文件一致。
class MarkdownPreviewView extends ConsumerStatefulWidget {
  const MarkdownPreviewView({
    super.key,
    required this.projectId,
    required this.path,
    this.immersive = false,
  });

  final String projectId;
  final String path;
  final bool immersive;

  @override
  ConsumerState<MarkdownPreviewView> createState() =>
      _MarkdownPreviewViewState();
}

class _MarkdownPreviewViewState extends ConsumerState<MarkdownPreviewView> {
  /// `null` = 还没手动切过，按文件体量决定默认模式。
  bool? _wantSource;

  @override
  Widget build(BuildContext context) {
    final content = ref.watch(
      projectFileContentProvider((
        projectId: widget.projectId,
        path: widget.path,
      )),
    );

    void toggleFullscreen() {
      final controller = ref.read(immersiveFullscreenProvider.notifier);
      if (widget.immersive) {
        controller.exit();
      } else {
        controller.enter(ImmersiveSurface.panel);
      }
    }

    return content.when(
      loading: () => const PreviewLoading(),
      error: (error, _) => PreviewErrorCard(
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(
          projectFileContentProvider((
            projectId: widget.projectId,
            path: widget.path,
          )),
        ),
      ),
      data: (file) {
        // 服务端按 UTF-8 原样返回，Windows 上的文件常带 CRLF；
        // 渲染与源码都按 LF 处理，行尾不会多出一个不可见字符。
        final text = file.text.replaceAll('\r\n', '\n');
        final oversized = text.length > _kMarkdownRenderMaxChars;
        final source = _wantSource ?? oversized;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 与文本预览一致：占位而不是 `if`，保持 `Expanded` 的槽位恒定。
            widget.immersive
                ? const SizedBox.shrink()
                : FilePreviewHeader(
                    path: file.path,
                    icon: Icons.article_outlined,
                    secondary: formatFileSize(file.size),
                    actions: <Widget>[
                      IconButton(
                        key: kMarkdownSourceToggleKey,
                        tooltip: source ? '预览' : '查看源码',
                        onPressed: () => setState(() => _wantSource = !source),
                        style: shellIconButtonStyle(
                          minimumSize: const Size.square(kPaneHeaderButtonSize),
                        ),
                        iconSize: kPaneHeaderIconSize,
                        icon: Icon(
                          source
                              ? Icons.visibility_outlined
                              : Icons.code_rounded,
                        ),
                      ),
                      IconButton(
                        key: kPreviewFullscreenKey,
                        tooltip: '全屏',
                        onPressed: toggleFullscreen,
                        style: shellIconButtonStyle(
                          minimumSize: const Size.square(kPaneHeaderButtonSize),
                        ),
                        iconSize: kPaneHeaderIconSize,
                        icon: const Icon(Icons.open_in_full_rounded),
                      ),
                      IconButton(
                        key: kPreviewSaveKey,
                        tooltip: '另存为',
                        onPressed: () => saveProjectFile(
                          context,
                          ref,
                          projectId: widget.projectId,
                          path: widget.path,
                        ),
                        style: shellIconButtonStyle(
                          minimumSize: const Size.square(kPaneHeaderButtonSize),
                        ),
                        iconSize: kPaneHeaderIconSize,
                        icon: const Icon(Icons.download_rounded),
                      ),
                    ],
                    onClose: () => ref
                        .read(filePaneTabProvider.notifier)
                        .closePreview(widget.path),
                  ),
            if (file.truncated) const PreviewTruncatedBanner(),
            Expanded(
              child: source
                  ? CodeView(
                      text: text,
                      language: syntaxLanguageOfAlias('markdown'),
                      storageKey: 'markdown-source:${widget.path}',
                    )
                  : _MarkdownBody(
                      text: text,
                      storageKey: 'markdown-preview:${widget.path}',
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _MarkdownBody extends StatelessWidget {
  const _MarkdownBody({required this.text, required this.storageKey});

  final String text;
  final String storageKey;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final monoStyle = AppText.of(context)
        .mono(size: AppFontSize.md, height: AppLineHeight.code);

    return SingleChildScrollView(
      key: PageStorageKey<String>(storageKey),
      padding: const EdgeInsets.fromLTRB(
        kPaneEdgeInset,
        12,
        kPaneContentInset,
        24,
      ),
      child: MarkdownBody(
        data: text,
        selectable: true,
        // 文档按标准 GFM 排版：单个换行不硬断行（那是聊天里为了迁就
        // 模型常用的"一行一句"才开的特例）。
        softLineBreak: false,
        styleSheet: _styleSheet(context, palette),
        builders: <String, MarkdownElementBuilder>{
          'pre': _DocCodeBlockBuilder(
            palette: palette,
            monoStyle: monoStyle,
            labelStyle: AppText.of(context).meta,
          ),
        },
        onTapLink: (text, href, title) => _copyLink(context, href),
      ),
    );
  }

  /// 文档级排版：比聊天气泡更舒展（段落间距更大、标题层级更明显），
  /// 颜色与字号仍全部来自 token，不新增裸值。
  MarkdownStyleSheet _styleSheet(BuildContext context, AppPalette palette) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(
      fontSize: AppFontSize.base,
      height: AppLineHeight.relaxed,
      color: palette.text.primary,
    );
    final mono = AppText.of(context)
        .mono(size: AppFontSize.md, height: AppLineHeight.code);

    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      pPadding: const EdgeInsets.only(top: 3, bottom: 3),
      blockSpacing: 10,
      a: body?.copyWith(
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary.withValues(alpha: 0.5),
      ),
      em: body?.copyWith(fontStyle: FontStyle.italic),
      strong: body?.copyWith(fontWeight: AppWeight.semiBold),
      del: body?.copyWith(decoration: TextDecoration.lineThrough),
      // 标题用内容标题 ramp（24 / 20 / 18 / 16）：预览页是整屏阅读，
      // 聊天里那套（20 / 18 / 16）会把长文档压成一篇平铺的段落。
      h1: body?.copyWith(
        fontSize: AppFontSize.displayLg,
        fontWeight: AppWeight.semiBold,
        height: AppLineHeight.tight,
      ),
      h1Padding: const EdgeInsets.only(top: 12, bottom: 6),
      h2: body?.copyWith(
        fontSize: AppFontSize.h1,
        fontWeight: AppWeight.semiBold,
        height: AppLineHeight.tight,
      ),
      h2Padding: const EdgeInsets.only(top: 10, bottom: 4),
      h3: body?.copyWith(
        fontSize: AppFontSize.h2,
        fontWeight: AppWeight.semiBold,
        height: AppLineHeight.tight,
      ),
      h3Padding: const EdgeInsets.only(top: 8, bottom: 3),
      h4: body?.copyWith(
        fontSize: AppFontSize.lg,
        fontWeight: AppWeight.semiBold,
      ),
      h4Padding: const EdgeInsets.only(top: 6, bottom: 2),
      h5: body?.copyWith(fontWeight: AppWeight.semiBold),
      h6: body?.copyWith(fontWeight: AppWeight.semiBold),
      // 行内代码保持无底色：句子里的 `print` 加底块会碎成一地色斑。
      code: mono.copyWith(color: scheme.onSurface),
      // 代码块的底色与内边距由 `MessageCodeBlock` 自己画，这里必须留空装饰：
      // 组件处理完自定义 builder 后仍会拿它包一层 Container。
      codeblockDecoration: const BoxDecoration(),
      blockquote: body?.copyWith(color: palette.text.secondary),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          left: BorderSide(color: scheme.outlineVariant, width: 3),
        ),
      ),
      listBullet: body,
      listBulletPadding: const EdgeInsets.only(right: 6),
      listIndent: 22,
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

  /// 与聊天区一致：不申请打开浏览器，复制链接并给一句提示。
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
}

/// 文档里的围栏代码块：与聊天共用 [MessageCodeBlock]，
/// 圆角底、语言标签、复制按钮、语法高亮都只有一份实现。
class _DocCodeBlockBuilder extends MarkdownElementBuilder {
  _DocCodeBlockBuilder({
    required this.palette,
    required this.monoStyle,
    required this.labelStyle,
  });

  final AppPalette palette;
  final TextStyle monoStyle;
  final TextStyle labelStyle;

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
      palette: palette.message,
      monoStyle: monoStyle,
      labelStyle: labelStyle,
    );
  }
}
