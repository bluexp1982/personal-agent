import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_error.dart';
import '../../core/artifact_naming.dart';
import '../../core/media_cache.dart';
import '../../core/media_save.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/save_media_dialog.dart';
import 'artifact_card.dart';
import 'artifact_thumbnail.dart';

/// 图片 / 视频产物卡片。
///
/// 外壳是 [ArtifactCard]（与生成文件卡同一套视觉），这里只负责两件媒体特有的事：
/// 1. 图片要在卡片里显示缩略图 → 需要按 id 惰性取字节（视频不取，打开才下载）；
/// 2. 保存要选落点（项目 / 本机）并预填 `会话标题_工具名_时间戳` 的名字。
///
/// 「打开」交给外部：落到右栏哪个标签由会话页决定，卡片不自己 push 路由。
class MediaArtifactCard extends ConsumerStatefulWidget {
  const MediaArtifactCard({
    super.key,
    required this.asset,
    this.conversationTitle = '',
    this.canSaveToProject = false,
    this.initialBytes,
    this.onOpen,
  });

  final MediaAsset asset;

  /// 会话标题：只用于自动命名。
  final String conversationTitle;

  /// 会话是否归属项目：决定「保存到项目」能不能选。
  final bool canSaveToProject;

  /// 已知字节（预加载 / 测试用）。为空时图片会自己按 id 去服务端取。
  final Uint8List? initialBytes;

  /// 打开预览；为空时按钮置灰。
  final ValueChanged<MediaAsset>? onOpen;

  @override
  ConsumerState<MediaArtifactCard> createState() => _MediaArtifactCardState();
}

class _MediaArtifactCardState extends ConsumerState<MediaArtifactCard> {
  Uint8List? _bytes;
  String? _error;

  /// 正在弹命名框 / 正存盘：按钮置灰避免连点开出两个框。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _bytes = widget.initialBytes;
    // 视频不需要卡片里的字节：缩略图是占位块，播放时才下载。
    if (widget.asset.isImage && _bytes == null) {
      _load();
    }
  }

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      setState(() => _error = '服务未连接');
      return;
    }
    setState(() => _error = null);
    try {
      final result = await client.getBytes(
        '/api/media/${Uri.encodeComponent(widget.asset.id)}/content',
      );
      if (!mounted) {
        return;
      }
      setState(() => _bytes = result.bytes);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.userMessage);
    }
  }

  /// 自动名：`会话标题_工具名_时间戳.扩展名`。
  String get _autoName => automaticArtifactName(
    conversationTitle: widget.conversationTitle,
    kind: widget.asset.kind,
    createdAtMs: widget.asset.createdAt,
    mime: widget.asset.mime,
  );

  /// 先选目标，再在命名框里确认文件名。
  Future<void> _saveTo(MediaSaveTarget target) async {
    if (_saving) {
      return;
    }
    _saving = true;
    try {
      await showSaveMediaDialog(
        context,
        title: target.label,
        initialName: _autoName,
        onSubmit: (name) => target == MediaSaveTarget.project
            ? saveMediaToProject(
                context,
                ref,
                mediaId: widget.asset.id,
                name: name,
              )
            : saveMediaToLocal(context, ref, asset: widget.asset, name: name),
      );
    } finally {
      _saving = false;
    }
  }

  List<AgentMenuItem<MediaSaveTarget>> _saveItems() {
    return <AgentMenuItem<MediaSaveTarget>>[
      AgentMenuItem<MediaSaveTarget>(
        key: kMediaSaveProjectKey,
        value: MediaSaveTarget.project,
        label: '保存到项目',
        icon: Icons.folder_outlined,
        // 无归属项目时置灰而不是隐藏：用户要知道"为什么这里不能存"。
        enabled: widget.canSaveToProject,
      ),
      AgentMenuItem<MediaSaveTarget>(
        key: kMediaSaveLocalKey,
        value: MediaSaveTarget.local,
        label: '保存到本地',
        icon: Icons.download_rounded,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    // 封面由服务端在生成时抽好；旧视频拿不到就直接是 null，回退占位块。
    final poster = asset.isImage
        ? null
        : ref.watch(mediaPosterProvider(asset.id)).asData?.value;

    return ArtifactCard(
      icon: asset.isImage ? Icons.image_outlined : Icons.movie_outlined,
      title: asset.isImage ? '生成的图片' : '生成的视频',
      primaryLine: _autoName,
      detailLine: asset.isImage
          ? asset.specLabel
          : '${asset.model} · ${asset.specLabel}',
      extraLines: <String>[
        if (!asset.isImage && asset.prompt.isNotEmpty) asset.prompt,
      ],
      thumbnail: asset.isImage
          ? ArtifactImageThumbnail(
              ratio: ArtifactImageThumbnail.ratioOf(
                width: asset.width,
                height: asset.height,
              ),
              bytes: _bytes,
              errorText: _error,
              onRetry: _load,
            )
          : ArtifactVideoThumbnail(
              label: asset.resolution ?? '',
              poster: poster,
            ),
      // 顺序与文件卡一致：保存在前、打开在后；打开图标三类产物共用一枚。
      actions: <Widget>[
        ArtifactSaveMenu<MediaSaveTarget>(
          key: kMediaSaveKey,
          enabled: !_saving,
          items: _saveItems(),
          onSelected: _saveTo,
        ),
        ArtifactActionButton(
          key: kMediaOpenKey,
          icon: kArtifactOpenIcon,
          label: '打开',
          onPressed: widget.onOpen == null
              ? null
              : () => widget.onOpen!(asset),
        ),
      ],
    );
  }
}

/// 卡片上动作的稳定锚点：测试按 Key 找，不按文案找。
const Key kMediaOpenKey = Key('artifact-card-open');
const Key kMediaSaveKey = Key('artifact-card-save');
const Key kMediaSaveProjectKey = Key('artifact-card-save-project');
const Key kMediaSaveLocalKey = Key('artifact-card-save-local');
