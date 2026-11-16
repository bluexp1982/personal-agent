import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/browser/browser_models.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/shell_layout_state.dart';
import 'browser_zoom_menu.dart';

/// 导航栏高度。
const double kBrowserToolbarHeight = 36;

/// 来源菜单的浮层宽度。
///
/// 「本机 / 服务器 / 互联网」都是短词，但太窄会让勾选项挤在边缘上，
/// 与全站菜单保持同一个量级。
const double kBrowserSourceMenuWidth = 200;

/// 地址框高度。
const double kBrowserAddressHeight = 28;

/// 地址文字的行盒高度：字号 × tight 行高，再留 1dp 抗锯齿余量。
///
/// 钉死行盒是刻意的：若让 28dp 的地址框直接约束输入框，多出来的空间一旦被
/// 算到文字上方，字就会贴底（截图实测偏下 4.5dp）。行盒只比文字高 1dp 之后，
/// 无论 InputDecorator 怎么竖直对齐，偏差都不会超过 0.5dp。
const double kBrowserAddressLineBox =
    AppFontSize.sm * AppLineHeight.tight + 1.2;

/// 浏览器导航栏：后退 / 前进 / 刷新停止 / 地址 / 缩放 / 系统浏览器打开。
///
/// 尺寸与颜色全部取自现有 `Theme`，不新增色值：右栏是同一个面板的一部分，
/// 换一套视觉会让"文件 / 终端 / 浏览器"看起来像三个应用拼起来的。
class BrowserToolbar extends StatefulWidget {
  const BrowserToolbar({
    super.key,
    required this.state,
    required this.onSubmit,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onStop,
    required this.onOpenExternal,
    required this.onSelectSource,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomReset,
  });

  final BrowserSessionState state;
  final ValueChanged<String> onSubmit;
  final VoidCallback onBack;
  final VoidCallback onForward;

  /// 刷新。带上地址栏此刻的文本：用户可能改了地址却没回车，
  /// 一律按"当前页"刷新会把他刚敲的地址悄悄丢掉。
  final ValueChanged<String> onReload;
  final VoidCallback onStop;
  final VoidCallback onOpenExternal;
  final ValueChanged<BrowserSource> onSelectSource;

  /// 页面缩放：+ / − / 回到 100%。三个动作都只改会话状态，
  /// 真正作用到 WebView 由 `BrowserPane` 负责（平台能力不同）。
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;

  @override
  State<BrowserToolbar> createState() => _BrowserToolbarState();
}

class _BrowserToolbarState extends State<BrowserToolbar> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text.text = widget.state.address;
    // 聚焦态只影响地址框描边：TextEditingController 不会触发本 widget 重建，
    // 自己监听一次焦点，避免"看起来没聚焦"。
    _focus.addListener(_handleFocusChanged);

    // 新建标签时，标签与地址栏在同一帧里挂载，`didUpdateWidget` 看不到
    // 已经发生的那次 focusRequest，这里补一次首帧聚焦。
    if (widget.state.focusRequest > 0) {
      _requestAddressFocus();
    }
  }

  void _handleFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 把焦点交给地址框并全选：新建空白标签时用户要做的第一件事就是输入地址，
  /// 全选让"再点一次浏览器"留下的内容也能一下覆盖掉。
  void _requestAddressFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _focus.requestFocus();
      _text.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _text.text.length,
      );
    });
  }

  @override
  void didUpdateWidget(covariant BrowserToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 聚焦时不覆盖用户正在输入的内容：页面加载完成会回填地址，
    // 那一下不该把刚敲了一半的地址清掉。
    if (!_focus.hasFocus && widget.state.address != _text.text) {
      _text.text = widget.state.address;
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    }
    if (widget.state.focusRequest != oldWidget.state.focusRequest) {
      _requestAddressFocus();
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_handleFocusChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  static final ButtonStyle _buttonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(26),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = widget.state;

    return SizedBox(
      height: kBrowserToolbarHeight,
      child: Padding(
        // 左（贴分隔线）扣掉栏缝的 8dp；右是窗口边，视觉左右同为 12dp。
        padding: const EdgeInsets.fromLTRB(
          kPaneEdgeInset,
          0,
          kPaneContentInset,
          0,
        ),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: '后退',
              onPressed: state.canGoBack ? widget.onBack : null,
              style: _buttonStyle,
              iconSize: 15,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            IconButton(
              tooltip: '前进',
              onPressed: state.canGoForward ? widget.onForward : null,
              style: _buttonStyle,
              iconSize: 15,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
            IconButton(
              tooltip: state.loading ? '停止加载' : '刷新',
              onPressed: state.hasPage
                  ? (state.loading
                        ? widget.onStop
                        : () => widget.onReload(_text.text))
                  : null,
              style: _buttonStyle,
              iconSize: 15,
              icon: Icon(
                state.loading ? Icons.close_rounded : Icons.refresh_rounded,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Container(
                height: kBrowserAddressHeight,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: _focus.hasFocus
                        ? scheme.primary.withValues(alpha: 0.7)
                        : scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    _SourceBadge(
                      source: state.source,
                      onSelected: widget.onSelectSource,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Center(
                        // 行盒定死在文字高度上（见 kBrowserAddressLineBox），
                        // 垂直居中交给 Center 与 Row：行盒与地址框之间那点余量
                        // 被压到 1dp 级，字不可能再被挤到底部。
                        heightFactor: 1,
                        child: SizedBox(
                          height: kBrowserAddressLineBox,
                          child: Focus(
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent &&
                                  event.logicalKey ==
                                      LogicalKeyboardKey.escape) {
                                _focus.unfocus();
                                widget.onStop();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: TextField(
                              controller: _text,
                              focusNode: _focus,
                              onSubmitted: (value) {
                                _focus.unfocus();
                                widget.onSubmit(value);
                              },
                              textAlignVertical: TextAlignVertical.center,
                              maxLines: 1,
                              // 行盒本身也锁死：forceStrutHeight 让行盒恰好是
                              // 1.2 倍字号，even 让上下留白相等。只设
                              // TextStyle.height 不够——行盒仍按字体的自然
                              // ascent/descent 排（中文约 1.4em），换字体就偏。
                              strutStyle: const StrutStyle(
                                fontSize: AppFontSize.sm,
                                height: AppLineHeight.tight,
                                leadingDistribution:
                                    TextLeadingDistribution.even,
                                forceStrutHeight: true,
                              ),
                              // 字号与右栏标签页一致（sm 11.5），同一栏里的两级
                              // 文字不再一大一小。字阶走 labelSmall 再覆盖，
                              // 与 _PanelTab 的标签文字同源。
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: AppFontSize.sm,
                                height: AppLineHeight.tight,
                                color: AppPalette.of(context).text.primary,
                                leadingDistribution:
                                    TextLeadingDistribution.even,
                              ),
                              cursorColor: scheme.primary,
                              decoration: InputDecoration(
                                isCollapsed: true,
                                border: InputBorder.none,
                                hintText: '输入 HTTP(S) 地址',
                                hintStyle: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: AppFontSize.sm,
                                  height: AppLineHeight.tight,
                                  leadingDistribution:
                                      TextLeadingDistribution.even,
                                  color: AppPalette.of(context).text.tertiary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 默认比例下不占位：100% 时没有"正在缩放"这件事，留一枚用不上的
            // 放大镜只会让工具条更吵。离开 100%（快捷键或浮层调档）后入口
            // 才出现，位置仍紧挨着外部打开。
            //
            // `hasPage` 兜住"空标签页 + 快捷键异常改比例"的边角：没有页面
            // 就没有可缩放的内容，不该冒出入口。
            if (state.hasPage && state.zoom != 1)
              BrowserZoomMenu(
                zoom: state.zoom,
                onZoomIn: widget.onZoomIn,
                onZoomOut: widget.onZoomOut,
                onReset: widget.onZoomReset,
              ),
            IconButton(
              tooltip: '在系统浏览器打开',
              onPressed: state.hasPage ? widget.onOpenExternal : null,
              style: _buttonStyle,
              iconSize: 15,
              icon: const Icon(Icons.open_in_new_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source, required this.onSelected});

  final BrowserSource source;
  final ValueChanged<BrowserSource> onSelected;

  static IconData _iconOf(BrowserSource value) => switch (value) {
    BrowserSource.client => Icons.computer_rounded,
    BrowserSource.server => Icons.dns_rounded,
    BrowserSource.internet => Icons.public_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    return AgentMenu<BrowserSource>(
      width: kBrowserSourceMenuWidth,
      tooltip: '选择来源',
      alignment: AlignmentDirectional.bottomStart,
      groups: <AgentMenuGroup<BrowserSource>>[
        AgentMenuGroup<BrowserSource>(
          items: <AgentMenuItem<BrowserSource>>[
            for (final value in BrowserSource.values)
              AgentMenuItem<BrowserSource>(
                value: value,
                label: value.label,
                icon: _iconOf(value),
                selected: value == source,
              ),
          ],
        ),
      ],
      onSelected: onSelected,
      // 中性徽标：底与字都取 `text.tertiary`，与「即将支持」角标同一套做法。
      // 它只是地址栏里的一枚来源标记，用主色会把它抬到与地址文本同级；
      // 悬停 / 展开时只把底色加深一格，与全站菜单触发器的反馈方式一致。
      builder: (context, controller, open, hovering) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: palette.text.tertiary.withValues(
            alpha: open || hovering ? 0.18 : 0.10,
          ),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(_iconOf(source), size: 12, color: palette.text.tertiary),
            const SizedBox(width: 3),
            // 徽标字阶走语义样式（10.5 / w600 / tertiary），不再手拼字号。
            Text(source.label, style: AppText.of(context).badge),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 13,
              color: palette.text.tertiary,
            ),
          ],
        ),
      ),
    );
  }
}
