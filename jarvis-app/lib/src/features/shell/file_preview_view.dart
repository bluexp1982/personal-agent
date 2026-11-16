import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/artifact_exporter.dart';
import '../../core/artifact_naming.dart';
import '../../core/file_preview_kind.dart';
import '../../core/media_cache.dart';
import '../../core/media_save.dart';
import '../../core/models.dart';
import '../../core/preview_source.dart';
import '../../core/project_file_providers.dart';
import '../../core/ui/save_media_dialog.dart';
import '../../core/ui/shell_icon_button.dart';
import '../preview/image_preview_view.dart';
import '../preview/markdown_preview_view.dart';
import '../preview/pdf_preview_view.dart';
import '../preview/preview_actions.dart';
import '../preview/preview_kind_icon.dart';
import '../preview/preview_states.dart';
import '../preview/text_preview_view.dart';
import '../preview/video_preview_view.dart';
import 'file_pane_state.dart';
import 'file_preview_header.dart';
import 'immersive_fullscreen.dart';
import 'shell_layout_state.dart';

// 两个动作锚点定义在 `file_preview_header.dart`（文本查看器自己画头部，
// 放在这里会形成双向 import）。这里转出一次，保持测试与既有调用方的
// `import 'file_preview_view.dart'` 不变。
export 'file_preview_header.dart'
    show kPreviewFullscreenKey, kPreviewSaveKey;

/// 预览标签的主体。
///
/// 路径由外面的标签传进来：一个文件一个标签，同一个组件实例不再"知道"自己
/// 是哪一份——读 provider 里的当前路径，会让两个标签互相串台。
///
/// 这里只做分流：文本交给 [TextPreviewView]，图片 / PDF 交给各自的查看器。
/// 分流必须在请求之前完成——图片若先请求 `/file`，用户会先看到一次
/// 「二进制文件无法预览」的报错，然后才看到图。
class FilePreviewView extends ConsumerWidget {
  const FilePreviewView({
    super.key,
    required this.path,
    this.projectId = '',
    this.asset,
    this.conversationTitle = '',
    this.immersive = false,
  });

  /// 这个标签对应的文件路径；[asset] 非空时是产物 id（仅用于日志与 Key）。
  final String path;

  /// 文件所属项目。为空时回退到"当前 shell 目标"——文件树打开的标签一直走
  /// 这条隐式路径；从会话产物打开的标签会显式带过来，因为那时右栏的
  /// shell 目标未必是会话所属的项目（窄屏整页形态尤其如此）。
  final String projectId;

  /// 会话产物（图片 / 视频）。非空表示这不是项目文件，字节走 `/api/media`。
  final MediaAsset? asset;

  /// 会话标题：产物另存时的自动命名要用它。
  final String conversationTitle;

  /// 沉浸式全屏：与终端、无限画布用的是同一个模式（`immersiveFullscreenProvider`）。
  ///
  /// 进来之后文件头整条收起——文件名、另存为都是"标签页"这一层的东西，
  /// 满屏时留着只会把图挤小一圈。底栏保留：缩放与翻页是内容自己的控制。
  final bool immersive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = this.asset;
    if (asset != null) {
      return _MediaPreview(
        asset: asset,
        conversationTitle: conversationTitle,
        immersive: immersive,
      );
    }

    // 同文件树：工具页占着中栏时仍按最后那个项目预览。
    final resolved = projectId.isNotEmpty
        ? projectId
        : ref.watch(shellProjectMemoProvider);

    if (resolved.isEmpty || path.isEmpty) {
      return const PreviewHint('没有可预览的文件');
    }

    return switch (previewKindOf(path)) {
      FilePreviewKind.text => TextPreviewView(
        projectId: resolved,
        path: path,
        immersive: immersive,
      ),
      // Markdown 仍走 `/file` 文本端点，只是默认渲染排版后的文档；
      // 放在 text 之后没有歧义（枚举分支互斥）。
      FilePreviewKind.markdown => MarkdownPreviewView(
        projectId: resolved,
        path: path,
        immersive: immersive,
      ),
      // 视频要单独一条：它吃的是本地文件而不是整片字节（拖动进度需要随机读取），
      // 与图片 / PDF 的数据源不是同一个 provider。
      FilePreviewKind.video => _VideoPreview(
        projectId: resolved,
        path: path,
        immersive: immersive,
      ),
      final kind => _BinaryPreview(
        projectId: resolved,
        path: path,
        kind: kind,
        immersive: immersive,
      ),
    };
  }
}

/// 会话产物（图片 / 视频）的预览。
///
/// 与项目文件同一套外壳：文件头（名称 / 规格 / 全屏 / 保存 / 关闭）+ 查看器。
/// 差别只在数据源与"另存为"的落点：产物不在项目目录里，只能存到本机或复制进
/// 项目的 `artifacts/`（后者在卡片上做，这里只给本机保存）。
class _MediaPreview extends ConsumerWidget {
  const _MediaPreview({
    required this.asset,
    required this.conversationTitle,
    required this.immersive,
  });

  final MediaAsset asset;
  final String conversationTitle;
  final bool immersive;

  /// 与卡片上「保存」预填的是同一个名字。
  String get _name => automaticArtifactName(
    conversationTitle: conversationTitle,
    kind: asset.kind,
    createdAtMs: asset.createdAt,
    mime: asset.mime,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabId = PreviewSource.mediaTabId(asset.id);

    void toggleFullscreen() {
      final controller = ref.read(immersiveFullscreenProvider.notifier);
      if (immersive) {
        controller.exit();
      } else {
        controller.enter(ImmersiveSurface.panel);
      }
    }

    Future<void> save() async {
      await showSaveMediaDialog(
        context,
        title: MediaSaveTarget.local.label,
        initialName: _name,
        onSubmit: (name) =>
            saveMediaToLocal(context, ref, asset: asset, name: name),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 收起文件头用占位而不是 `if`：子级数量一变，下面的 `Expanded`
        // 会换槽位被当成新子树，视频播放器跟着重开——双击进出全屏时
        // 会表现为"视频从头开始"。
        immersive
            ? const SizedBox.shrink()
            : FilePreviewHeader(
                path: _name,
                icon: asset.isImage
                    ? Icons.image_outlined
                    : Icons.movie_outlined,
                secondary: asset.specLabel,
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
                    onPressed: save,
                    style: shellIconButtonStyle(
                      minimumSize: const Size.square(kPaneHeaderButtonSize),
                    ),
                    iconSize: kPaneHeaderIconSize,
                    icon: const Icon(Icons.download_rounded),
                  ),
                ],
                onClose: () => ref
                    .read(filePaneTabProvider.notifier)
                    .closePreview(tabId),
              ),
        Expanded(
          child: asset.isImage
              ? _imageBody(ref)
              : _videoBody(ref, toggleFullscreen),
        ),
      ],
    );
  }

  Widget _imageBody(WidgetRef ref) {
    final data = ref.watch(mediaImageBytesProvider(asset.id));
    return data.when(
      loading: () => const PreviewLoading(),
      error: (error, _) => PreviewErrorCard(
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(mediaImageBytesProvider(asset.id)),
      ),
      data: (bytes) => ImagePreviewView(path: _name, bytes: bytes),
    );
  }

  Widget _videoBody(WidgetRef ref, VoidCallback toggle) {
    final key = VideoSourceKey.conversationMedia(
      mediaId: asset.id,
      extension: extensionForMime(asset.mime),
    );
    final data = ref.watch(videoFileProvider(key));
    // 起播前用同一张封面占住画面，避免右栏先黑一块再出画。
    final poster = ref.watch(mediaPosterProvider(asset.id)).asData?.value;
    return data.when(
      loading: () => const PreviewLoading(),
      error: (error, _) => PreviewErrorCard(
        message: error is ApiException ? error.userMessage : '$error',
        onRetry: () => ref.invalidate(videoFileProvider(key)),
      ),
      data: (file) => VideoPreviewView(
        path: _name,
        file: file,
        poster: poster,
        // 底栏不再有全屏键：进 / 出全屏是双击画面（文件头按钮在非沉浸态
        // 仍是主入口，沉浸态则靠 Esc 或再双击画面退出）。
        onToggleFullscreen: toggle,
        immersive: immersive,
      ),
    );
  }
}

/// 视频文件：文件头 + 播放器。
///
/// 文件头与图片 / PDF 同一套（文件名、大小、全屏、另存为）：用户点开一个文件
/// 应先确认"打开的是哪一份"，播放器本身不重复表达这件事。
class _VideoPreview extends ConsumerWidget {
  const _VideoPreview({
    required this.projectId,
    required this.path,
    required this.immersive,
  });

  final String projectId;
  final String path;
  final bool immersive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = VideoSourceKey.projectFile(
      projectId: projectId,
      path: path,
      extension: videoExtensionOfPath(path),
    );
    final data = ref.watch(videoFileProvider(key));

    void toggleFullscreen() {
      final controller = ref.read(immersiveFullscreenProvider.notifier);
      if (immersive) {
        controller.exit();
      } else {
        controller.enter(ImmersiveSurface.panel);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 同 `_MediaPreview`：占位保持槽位恒定，切全屏不重建播放器。
        immersive
            ? const SizedBox.shrink()
            : FilePreviewHeader(
                path: path,
                icon: previewIconOf(FilePreviewKind.video),
                secondary: data.maybeWhen(
                  data: (file) => _sizeLabel(file),
                  orElse: () => '',
                ),
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
                onClose: () =>
                    ref.read(filePaneTabProvider.notifier).closePreview(path),
              ),
        Expanded(
          child: data.when(
            loading: () => const PreviewLoading(),
            error: (error, _) => PreviewErrorCard(
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(videoFileProvider(key)),
            ),
            data: (file) => VideoPreviewView(
              path: path,
              file: file,
              // 沉浸态下文件头与底栏都收起，退出全屏靠 Esc 或再双击画面。
              onToggleFullscreen: toggleFullscreen,
              immersive: immersive,
              // 解码失败时不给「用系统应用打开」：这里手上只有临时文件，
              // 真要点开得再下载一遍字节；提示改为另存为即可。
            ),
          ),
        ),
      ],
    );
  }
}

/// 图片 / PDF / 不支持格式：文件头 + 查看器。
///
/// 文件头常显（哪怕还在加载）：用户点了文件就想看见"打开的是哪一份"，
/// 先给一段转圈、连文件名都不给会像是点错了。
class _BinaryPreview extends ConsumerWidget {
  const _BinaryPreview({
    required this.projectId,
    required this.path,
    required this.kind,
    required this.immersive,
  });

  final String projectId;
  final String path;
  final FilePreviewKind kind;
  final bool immersive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (projectId: projectId, path: path);
    final data = ref.watch(projectFileBytesProvider(key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!immersive)
          FilePreviewHeader(
            path: path,
            icon: previewIconOf(kind),
            secondary: data.maybeWhen(
              data: (file) => formatFileSize(file.size),
              orElse: () => '',
            ),
            actions: <Widget>[
              if (kind != FilePreviewKind.unsupported)
                IconButton(
                  key: kPreviewFullscreenKey,
                  tooltip: '全屏',
                  // 与终端同一个入口出口：进的是面板的沉浸模式，
                  // 不是另开一页，也不再自带一套标题栏与浮动工具条。
                  onPressed: () => ref
                      .read(immersiveFullscreenProvider.notifier)
                      .enter(ImmersiveSurface.panel),
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
            onClose: () =>
                ref.read(filePaneTabProvider.notifier).closePreview(path),
          ),
        Expanded(
          child: data.when(
            loading: () => const PreviewLoading(),
            // 上限、越界、文件被删都由服务端给出可直接展示的文案，
            // 这里原样透出，不自己拼一句更模糊的。
            error: (error, _) => PreviewErrorCard(
              message: error is ApiException ? error.userMessage : '$error',
              onRetry: () => ref.invalidate(projectFileBytesProvider(key)),
            ),
            data: (file) => switch (kind) {
              FilePreviewKind.image => ImagePreviewView(
                path: path,
                bytes: file.bytes,
              ),
              FilePreviewKind.pdf => PdfPreviewView(
                path: path,
                bytes: file.bytes,
              ),
              _ => const PreviewHint('内置查看器暂不支持该格式，可另存为后用系统应用打开'),
            },
          ),
        ),
      ],
    );
  }
}

/// 文件头右上角的大小文案。
///
/// 文件在拿到之后仍可能被清理（临时目录是共享的），取不到就返回空串——
/// 为了一个副标题让整页抛 `PathNotFoundException` 不值得。
String _sizeLabel(File file) {
  try {
    return formatFileSize(file.lengthSync());
  } on FileSystemException {
    return '';
  }
}




