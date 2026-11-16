import 'package:flutter/material.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/shell_layout_state.dart';

/// 图片 / PDF 查看器共用的底栏。
///
/// 只做「缩放」与「跳页」两件事：全屏与另存为属于文件级动作，放在文件头上，
/// 两者的入口不该混在同一行里。尺寸、页数这类只读信息走 [info] / [pageLabel]。
class PreviewToolbar extends StatelessWidget {
  const PreviewToolbar({
    super.key,
    required this.zoomPercent,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onActualSize,
    this.info,
    this.pageLabel,
    this.onPreviousPage,
    this.onNextPage,
    this.opaque = true,
  });

  /// 当前缩放百分比（100 = 适应窗口时的原始比例由各查看器自己定义）。
  final int zoomPercent;

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onActualSize;

  /// 只读信息，例如图片的 `1920×1080 · 2.4 MB`。
  final String? info;

  /// 页码文案，例如 `第 3 / 42 页`。为空时不出现翻页按钮。
  final String? pageLabel;

  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;

  /// 是否画底色与上边框。全屏页铺在黑底上时传 false，免得出现一条突兀的横线。
  final bool opaque;

  static final ButtonStyle _buttonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final textStyle = TextStyle(
      fontSize: AppFontSize.xs,
      color: palette.text.secondary,
      // 数字宽度会随缩放变化，固定字宽可以避免整条底栏左右抖。
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    Widget iconButton({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback? onPressed,
    }) {
      return IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        style: _buttonStyle,
        iconSize: kPaneHeaderIconSize,
        icon: Icon(icon),
      );
    }

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: kPaneContentInset),
      decoration: BoxDecoration(
        color: opaque ? scheme.surface : null,
        border: opaque
            ? Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
              )
            : null,
      ),
      child: Row(
        children: <Widget>[
          if (info != null && info!.isNotEmpty) ...<Widget>[
            Flexible(
              child: Text(
                info!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            const SizedBox(width: 10),
          ],
          iconButton(
            key: kPreviewZoomOutKey,
            tooltip: '缩小',
            icon: Icons.remove_rounded,
            onPressed: onZoomOut,
          ),
          SizedBox(
            width: 42,
            child: Text(
              '$zoomPercent%',
              textAlign: TextAlign.center,
              maxLines: 1,
              style: textStyle,
            ),
          ),
          iconButton(
            key: kPreviewZoomInKey,
            tooltip: '放大',
            icon: Icons.add_rounded,
            onPressed: onZoomIn,
          ),
          const SizedBox(width: 4),
          iconButton(
            key: kPreviewFitKey,
            tooltip: '适应窗口',
            icon: Icons.fit_screen_outlined,
            onPressed: onFit,
          ),
          iconButton(
            key: kPreviewActualSizeKey,
            tooltip: '实际大小',
            icon: Icons.crop_original_rounded,
            onPressed: onActualSize,
          ),
          const Spacer(),
          if (pageLabel != null) ...<Widget>[
            iconButton(
              key: kPreviewPreviousPageKey,
              tooltip: '上一页',
              icon: Icons.keyboard_arrow_up_rounded,
              onPressed: onPreviousPage,
            ),
            Text(pageLabel!, maxLines: 1, style: textStyle),
            iconButton(
              key: kPreviewNextPageKey,
              tooltip: '下一页',
              icon: Icons.keyboard_arrow_down_rounded,
              onPressed: onNextPage,
            ),
          ],
        ],
      ),
    );
  }
}

/// 底栏上的稳定锚点：测试与无障碍定位都按 Key 找，不按图标字形找。
const Key kPreviewZoomOutKey = Key('preview-toolbar-zoom-out');
const Key kPreviewZoomInKey = Key('preview-toolbar-zoom-in');
const Key kPreviewFitKey = Key('preview-toolbar-fit');
const Key kPreviewActualSizeKey = Key('preview-toolbar-actual');
const Key kPreviewPreviousPageKey = Key('preview-toolbar-previous-page');
const Key kPreviewNextPageKey = Key('preview-toolbar-next-page');
