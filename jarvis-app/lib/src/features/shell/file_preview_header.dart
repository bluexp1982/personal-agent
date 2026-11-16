import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import '../../core/ui/shell_icon_button.dart';
import 'shell_layout_state.dart';

/// 预览标签的文件头：文件名 + 一行次要信息 + 动作插槽 + 关闭。
///
/// 三种查看器（文本 / 图片 / PDF）共用这一份：过去它长在文本预览里，
/// 复制两份之后必然出现"图片上的关闭键 8dp、文本上的 12dp"这种漂移。
///
/// [secondary] 是纯文案（体积、尺寸、页数），由各查看器自己算——
/// 组件不猜类型，也不自己去读 provider。
/// 预览标签栏上与文件级动作的稳定锚点（测试与无障碍定位都用它们）。
///
/// 放在文件头这一层而不是某个查看器里：文本 / 图片 / PDF / 视频都要用，
/// 而文本查看器自己画头部（不再经过 `FilePreviewView` 的 `_BinaryPreview`），
/// 留在原处会让两层互相 import。
const Key kPreviewFullscreenKey = Key('preview-fullscreen');
const Key kPreviewSaveKey = Key('preview-save');

class FilePreviewHeader extends StatelessWidget {
  const FilePreviewHeader({
    super.key,
    required this.path,
    required this.onClose,
    required this.secondary,
    this.icon = Icons.description_outlined,
    this.actions = const <Widget>[],
    this.closeTooltip = '关闭预览',
  });

  /// 服务端绝对路径，同时用来取文件名与悬停提示。
  final String path;

  final VoidCallback onClose;

  /// 第二行文案。空串时不占位（宁可少一行，也不要一条空白）。
  final String secondary;

  final IconData icon;

  /// 追加在关闭键左侧的动作（全屏、另存为）。样式由调用方给。
  final List<Widget> actions;

  /// 关闭键的 tooltip。全屏页里它表示「退出全屏」，语义不同，文案也要跟着换。
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      // 左（贴分隔线）扣掉栏缝的 8dp；右是窗口边，视觉左右同为 12dp。
      padding: const EdgeInsets.fromLTRB(
        kPaneEdgeInset,
        6,
        kPaneContentInset,
        6,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: path,
              waitDuration: const Duration(milliseconds: 500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    fileNameOf(path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontSize: AppFontSize.sm,
                      fontWeight: AppWeight.semiBold,
                      color: AppPalette.of(context).text.primary,
                    ),
                  ),
                  if (secondary.isNotEmpty)
                    Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: AppFontSize.xs,
                        color: AppPalette.of(context).text.tertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          ...actions,
          IconButton(
            tooltip: closeTooltip,
            onPressed: onClose,
            // 与同一屏标签栏上的「+ / 全屏 / 隐藏」同一套规格：命中区 24、
            // 图标 14、8dp 圆角方形悬停底。行的呼吸感交给 header 的 padding，
            // 不在这里按行高另开一套尺寸。
            style: shellIconButtonStyle(
              minimumSize: const Size.square(kPaneHeaderButtonSize),
            ),
            iconSize: kPaneHeaderIconSize,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
