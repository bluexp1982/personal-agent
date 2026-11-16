import 'package:flutter/material.dart';

import '../../core/browser/browser_zoom.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/shell_icon_button.dart';

/// 缩放浮层的宽度。
///
/// 定值而不是跟内容伸缩：比例从 `25%` 走到 `500%` 只多一个字符，若让浮层
/// 自己量宽，每调一档整块面板都会横向抖一下。180 与 Chrome 那颗气泡同量级：
/// 塞得下 `500%`、`−`、`+` 与「重置」胶囊，又不至于把三个按钮摊成一条散线。
const double kBrowserZoomMenuWidth = 180;

/// 工具条上缩放按钮的稳定锚点。
const Key kBrowserZoomButtonKey = Key('browser-zoom-button');

/// 缩小 / 放大 / 重置与比例文本的稳定锚点。
const Key kBrowserZoomOutKey = Key('browser-zoom-out');
const Key kBrowserZoomInKey = Key('browser-zoom-in');
const Key kBrowserZoomResetKey = Key('browser-zoom-reset');
const Key kBrowserZoomPercentKey = Key('browser-zoom-percent');

/// 工具条上的缩放入口：一枚按钮 + 一个 Chrome 式的比例气泡。
///
/// 只在比例非 100% 时由工具条渲染（见 `browser_toolbar.dart`）：默认比例下
/// 没有"正在缩放"这件事，这个组件整个不存在，因此内部也没有"重置禁用"
/// 这种中间态。
///
/// 面板外观全部来自 [AgentMenuStyle]（同一套底色、圆角、阴影与描边），
/// 但内容不是菜单条目：`menuChildren` 放自定义 Row，于是点 −/+/重置
/// 不会像 [MenuItemButton] 那样顺手收起浮层——这正是 Chrome 的手感，
/// 连点几档时不需要每次重新打开。
class BrowserZoomMenu extends StatefulWidget {
  const BrowserZoomMenu({
    super.key,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  /// 当前比例（1 = 100%）。
  final double zoom;

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  State<BrowserZoomMenu> createState() => _BrowserZoomMenuState();
}

class _BrowserZoomMenuState extends State<BrowserZoomMenu> {
  final MenuController _controller = MenuController();

  void _toggle() {
    if (_controller.isOpen) {
      _controller.close();
    } else {
      _controller.open();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      // 面板右缘贴住按钮右缘：这一枚紧邻"在系统浏览器打开"，再往右就是
      // 窗口边，右对齐才不会被 Overlay 裁掉最外侧那 1px 描边。
      alignmentOffset: AgentMenuStyle.rightAlignedOffset(kBrowserZoomMenuWidth),
      style: AgentMenuStyle.panelStyleOf(context).copyWith(
        alignment: AlignmentDirectional.bottomEnd,
        minimumSize: const WidgetStatePropertyAll<Size>(
          Size(kBrowserZoomMenuWidth, 0),
        ),
      ),
      menuChildren: <Widget>[_content(context)],
      builder: (context, controller, _) => IconButton(
        key: kBrowserZoomButtonKey,
        tooltip: '缩放',
        onPressed: _toggle,
        style: shellIconButtonStyle(minimumSize: const Size.square(26)),
        iconSize: 15,
        icon: const Icon(Icons.zoom_in_rounded),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final palette = AppPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final canOut = previousBrowserZoom(widget.zoom) != null;
    final canIn = nextBrowserZoom(widget.zoom) != null;

    // 与右栏顶部标签页同字号（sm / 11.5）：浮层属于同一条工具带，文字
    // 比标签大一号会让它看起来像另一套控件。`meta` 就是「小字 + tight
    // 行高」，这里只把颜色从 tertiary 提为 primary。
    final labelStyle = AppText.of(context).meta.copyWith(
      color: palette.text.primary,
    );

    // 宽度写死而不是靠 Spacer：菜单面板外层套着 `IntrinsicWidth`，
    // 带 flex 的 Row 在固有宽度测量里会拿不到有界约束。
    return SizedBox(
      width: kBrowserZoomMenuWidth - AgentMenuStyle.panelPadding * 2,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(
              browserZoomLabel(widget.zoom),
              key: kBrowserZoomPercentKey,
              maxLines: 1,
              style: labelStyle,
            ),
          ),
          // − / + / 重置收进一个贴右的紧凑组：此前四个子项一起
          // `spaceBetween`，三个按钮被均分到整行，看着像三颗互不相干的
          // 控件。成组之后只剩"比例 ↔ 一组按钮"这一处留白。
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                key: kBrowserZoomOutKey,
                tooltip: '缩小',
                onPressed: canOut ? widget.onZoomOut : null,
                style: shellIconButtonStyle(
                  minimumSize: const Size.square(24),
                  radius: 6,
                ),
                iconSize: 15,
                icon: const Icon(Icons.remove_rounded),
              ),
              IconButton(
                key: kBrowserZoomInKey,
                tooltip: '放大',
                onPressed: canIn ? widget.onZoomIn : null,
                style: shellIconButtonStyle(
                  minimumSize: const Size.square(24),
                  radius: 6,
                ),
                iconSize: 15,
                icon: const Icon(Icons.add_rounded),
              ),
              const SizedBox(width: 6),
              // 入口只在非 100% 时渲染，所以这里不存在"100% 下灰掉的
              // 禁用态"：100% 时整个浮层已经跟着入口一起消失。
              TextButton(
                key: kBrowserZoomResetKey,
                onPressed: widget.onReset,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 24),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  // 描边只表达"这是一枚独立的胶囊"，不另加一层底色。
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    side: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                child: Text(
                  '重置',
                  style: labelStyle.copyWith(color: scheme.primary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
