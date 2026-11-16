import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/models.dart';
import '../../core/project_file_providers.dart';
import '../../core/syntax/syntax_language.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/file_pane_state.dart';
import '../shell/file_preview_header.dart';
import '../shell/immersive_fullscreen.dart';
import '../shell/shell_layout_state.dart';
import 'code_view.dart';
import 'preview_actions.dart';
import 'preview_states.dart';

/// 代码 / 文本文件查看器：文件头 + 截断横幅 + 带行号与语法高亮的正文。
///
/// 与 `ImagePreviewView` / `PdfPreviewView` 并列，只负责"把一份文本画出来"。
/// 分流仍在 `FilePreviewView` 里做：图片若先请求 `/file`，用户会先吃一次
/// 「二进制文件无法预览」的报错，然后才看到图。
///
/// 路径由外面的预览标签传进来：一个文件一个标签，同一个组件实例不再"知道"
/// 自己是哪一份——读全局的"当前文件"会让两个标签互相串台。
class TextPreviewView extends ConsumerWidget {
  const TextPreviewView({
    super.key,
    required this.projectId,
    required this.path,
    this.immersive = false,
  });

  final String projectId;

  /// 文件的服务端绝对路径。
  final String path;

  /// 沉浸式全屏：与图片 / PDF 同一套（`immersiveFullscreenProvider`），
  /// 进满屏后文件头整条收起，阅读区撑满窗口。
  final bool immersive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = ref.watch(
      projectFileContentProvider((projectId: projectId, path: path)),
    );

    void toggleFullscreen() {
      final controller = ref.read(immersiveFullscreenProvider.notifier);
      if (immersive) {
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
          projectFileContentProvider((projectId: projectId, path: path)),
        ),
      ),
      data: (file) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 收起文件头用占位而不是 `if`：子级数量一变，下面的 `Expanded`
          // 会换槽位被当成新子树，进出全屏时滚动位置会跟着丢。
          immersive
              ? const SizedBox.shrink()
              : FilePreviewHeader(
                  path: file.path,
                  secondary: formatFileSize(file.size),
                  actions: <Widget>[
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
                        projectId: projectId,
                        path: path,
                      ),
                      style: shellIconButtonStyle(
                        minimumSize: const Size.square(kPaneHeaderButtonSize),
                      ),
                      iconSize: kPaneHeaderIconSize,
                      icon: const Icon(Icons.download_rounded),
                    ),
                  ],
                  // 只关这个标签自己：别的文件标签还开着，不能一起收掉。
                  onClose: () =>
                      ref.read(filePaneTabProvider.notifier).closePreview(path),
                ),
          if (file.truncated) const PreviewTruncatedBanner(),
          Expanded(
            child: CodeView(
              // 服务端按 UTF-8 原样返回，Windows 上的文件常带 CRLF。
              // 统一成 LF：行尾的 `\r` 会让 `Text` 多出一个不可见字符，
              // 行号与复制结果也跟着带上它。
              text: file.text.replaceAll('\r\n', '\n'),
              language: syntaxLanguageOfPath(file.path),
              storageKey: 'text-preview:$path',
            ),
          ),
        ],
      ),
    );
  }
}
