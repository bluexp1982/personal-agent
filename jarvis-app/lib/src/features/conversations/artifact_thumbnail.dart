import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';

/// 图片缩略图的最大高度。
///
/// 占位骨架与成品图共用这一个上限：先按资产宽高比算出盒子，再往里放内容，
/// 于是「骨架 → 图片」只是换像素，不换尺寸。以前骨架按列宽铺满（1:1 图在
/// 700dp 宽的列里就是 700 高），成图却限高 280，字节一到位内容整体矮掉几百
/// 像素，贴底的列表被顶出底部再弹回来——那正是会话详情页"抽动"的来源。
const double kMediaImageMaxHeight = 280;

/// 比例下限 / 上限：极端长条图不能把卡片撑成一条缝或一根柱子。
const double _minImageRatio = 0.5;
const double _maxImageRatio = 2.5;

/// 图片缩略图：盒子大小**只由资产自身的宽高比决定**。
///
/// 骨架（[bytes] 为空）与成品套同一个 `AspectRatio`，字节到达、解码完成都
/// 只是原地换内容，卡片高度一个像素都不变。
class ArtifactImageThumbnail extends StatelessWidget {
  const ArtifactImageThumbnail({
    super.key,
    required this.ratio,
    this.bytes,
    this.errorText,
    this.onRetry,
  });

  /// 宽高比；调用方按 `width / height` 算好并已收进 [0.5, 2.5]。
  final double ratio;

  /// 为空表示还在取字节。
  final Uint8List? bytes;

  /// 取图失败的原因；非空时整块变成可点重试的提示。
  final String? errorText;

  final VoidCallback? onRetry;

  /// 按资产宽高比归一：缺宽高时 1:1，极端比例收进 [0.5, 2.5]。
  static double ratioOf({int? width, int? height}) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return 1;
    }
    return (width / height).clamp(_minImageRatio, _maxImageRatio).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;

    final Widget content;
    if (errorText != null) {
      content = GestureDetector(
        onTap: onRetry,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.broken_image_outlined, color: palette.text.tertiary),
                const SizedBox(height: 6),
                Text(
                  '$errorText\n点击重试',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppFontSize.sm,
                    color: palette.text.tertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else if (bytes == null) {
      content = ColoredBox(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
        ),
      );
    } else {
      content = Image.memory(
        bytes!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => ColoredBox(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          child: Center(
            child: Text(
              '这张图打不开',
              style: TextStyle(fontSize: AppFontSize.sm, color: palette.text.tertiary),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽列里不铺满：按限高换算宽度，避免 1:1 图在 700 宽的列里变成 700 高。
        final maxWidth = kMediaImageMaxHeight * ratio;
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(0.0, maxWidth)
            : maxWidth;
        return SizedBox(
          width: width,
          height: width / ratio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: content,
          ),
        );
      },
    );
  }
}

/// 视频缩略图：16:9 画面 + 播放标记。
///
/// 封面由服务端在生成视频时抽好（`/api/media/{id}/poster`），客户端不再自己
/// 抽帧——那意味着为了列表里一张卡把整段几十 MB 的视频下载到本机。
/// 没有封面（旧视频 / 服务端没装 ffmpeg）时退回纯色占位块 + 播放图标。
class ArtifactVideoThumbnail extends StatelessWidget {
  const ArtifactVideoThumbnail({super.key, this.label = '', this.poster});

  /// 右下角的小字（分辨率档位之类）。
  final String label;

  /// 封面字节；为空表示还没有封面。
  final Uint8List? poster;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cover = poster;

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (cover == null)
              ColoredBox(color: scheme.surfaceContainerHighest)
            else
              Image.memory(
                cover,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // 封面解不开时退回占位底色，别让整张卡变成一个破裂图标。
                errorBuilder: (context, error, stack) =>
                    ColoredBox(color: scheme.surfaceContainerHighest),
              ),
            Center(
              child: Icon(
                Icons.play_circle_outline,
                size: 36,
                color: cover == null
                    ? palette.text.secondary
                    // 封面底上要看得清：白描边 + 半透明底由 token 派生。
                    : palette.text.onAccent,
                shadows: cover == null
                    ? null
                    : <Shadow>[
                        Shadow(
                          color: scheme.shadow.withValues(alpha: 0.35),
                          blurRadius: 8,
                        ),
                      ],
              ),
            ),
            if (label.isNotEmpty)
              Positioned(
                right: 8,
                bottom: 6,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    color: cover == null
                        ? palette.text.tertiary
                        : palette.text.onAccent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
