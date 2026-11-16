import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_text_styles.dart';
import '../design/app_tokens.dart';
import 'shell_icon_button.dart';

/// 弹窗标题行高度。关闭钮在行内垂直居中，上下留白 = (行高 - 钮高) ÷ 2。
const double kAppDialogTitleBarHeight = 48;

/// 关闭钮 / 标题行前置动作的命中区边长。
///
/// 与栏头那批 24 见方的图标钮同一族，只是大一号：20 号图标配 32 时底框 / 图标
/// = 1.6，与栏头的 1.71 最接近；M3 默认的 40（2.0）在标题行里显得比图标本身重
/// 得多。所有自绘标题栏的弹窗都用这一档，别再各写一个尺寸。
const double kAppDialogCloseButtonSize = 32;

/// 标题行右侧内边距。
///
/// 与上下留白复用同一个算式，所以「上边距 = 右边距」是结构保证，不是"按钮恰好
/// 32"的巧合：按钮或行高一改，三边一起跟着变。
const double kAppDialogEndInset =
    (kAppDialogTitleBarHeight - kAppDialogCloseButtonSize) / 2;

/// 标题文字的左内边距：与内容行同一条内容线（20）。
const double kAppDialogTitleStartInset = 20;

/// 标题行左侧有动作（「上一级」这类）时的左内边距。
///
/// 收到 8，让那枚钮贴近边沿：这样左右两侧各一枚 32 的钮时，居中的标题才是真
/// 居中，不会被 20 的左内边距顶偏。
const double kAppDialogTitleStartInsetWithLeading = 8;

/// 标题行图标钮的悬停底圆角：32 见方按栏头的 8 : 24 换算，约 10.67。
final double kAppDialogIconButtonRadius = shellIconButtonRadiusFor(
  kAppDialogCloseButtonSize,
);

/// 标题行里图标钮（关闭 / 上一级）的统一形态：32 见方、圆角方形、颜色交给主题。
///
/// 圆角按 8 : 24 的比例从栏头那档换算（[shellIconButtonRadiusFor]），不手写圆角。
final ButtonStyle kAppDialogIconButtonStyle = shellIconButtonStyle(
  minimumSize: const Size.square(kAppDialogCloseButtonSize),
  radius: kAppDialogIconButtonRadius,
);

/// 全站弹窗的遮罩强度（`colorScheme.scrim` 的 alpha）。
///
/// 比 Material 默认的 54% 略轻：既压得住背景，又不至于把整页压黑；再深就贴到
/// 0.54。改这一处就是全站 `AppDialog` 的遮罩深浅，调用方没有覆盖入口。
const double kAppDialogBarrierAlpha = 0.45;

/// 打开一个 [AppDialog]。
///
/// 遮罩深浅属于组件的视觉契约，由本文件决定，调用方不参与——直接用 `showDialog`
/// 会落回 Material 默认的 54%，比这里的基准重一档。五个弹窗都从这里进。
///
/// 也不暴露 `barrierDismissible`：当前各处都需要"点遮罩关闭"，多一个参数只会让
/// 行为在五个弹窗之间漂移。
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final scheme = Theme.of(context).colorScheme;
  return showDialog<T>(
    context: context,
    barrierColor: scheme.scrim.withValues(alpha: kAppDialogBarrierAlpha),
    builder: builder,
  );
}

/// 全站弹窗的统一外壳。
///
/// 只负责「一条弹窗长什么样」：尺寸盒、标题行、关闭钮、内容区、可选底部动作区，
/// 以及 Esc 兜底。内容、返回值、是否滚动由调用方决定，因此它既装得下左右分栏的
/// 设置浮层，也装得下 520 宽的表单与 560 宽的目录选择器。
///
/// 几处刻意的取舍：
/// - 内容用 `Flexible` 而不是 `Expanded`：表单弹窗要贴着内容长高，而目录选择器
///   那种内部自带 `Expanded` 的列表在拿到有界高度后仍会撑满。
/// - 颜色一律不写死：关闭钮的悬停灰、前景色、禁用态都沿主题，和栏头图标钮同源。
/// - 底色按亮度分档，**不给覆盖参数**：浅色取 `colorScheme.surface`（与页面同色，
///   靠遮罩与圆角分层）；深色取 `colorScheme.surfaceContainerHigh`（页面底在深色下
///   接近纯黑，只有"比其他容器亮一档"才看得出浮层——M3 表达深色 elevation 的正规
///   做法）。主题包想控制深色弹窗的浮起层，覆盖 `scheme.surface_container_high` 即可。
/// - 遮罩同理只走 [showAppDialog]。将来确实要例外再开参数，别提前留口子。
/// - 标题字号默认 [AppText.dialogTitle]（22 / w700），需要例外时才传 [titleStyle]。
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    this.dialogKey,
    this.panelKey,
    this.title,
    this.titleWidget,
    this.titleStyle,
    this.titleAlign = TextAlign.start,
    this.subtitle,
    this.leading,
    this.titleTrailing,
    this.child,
    this.actions,
    this.width,
    this.height,
    this.maxWidth = 520,
    this.maxHeight,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 24,
      vertical: 32,
    ),
    this.contentPadding = const EdgeInsets.fromLTRB(20, 10, 20, 20),
    this.scrollable = true,
    this.onClose,
    this.closeKey,
    this.closeTooltip = '关闭',
    this.shape,
    this.clipBehavior = Clip.antiAlias,
  }) : assert(
         title != null || titleWidget != null || titleTrailing != null,
         '标题行至少要有一件东西：标题、自定义标题或自定义右侧动作',
       );

  /// 挂到根 `Dialog` 上（测试用来确认"弹窗在不在"）。
  final Key? dialogKey;

  /// 挂到内部的尺寸盒上（`Dialog` 铺满整屏，量尺寸要量这一层）。
  final Key? panelKey;

  /// 标题文字。与 [titleWidget] 二选一。
  final String? title;

  /// 完全自定义的标题（居中标题、图标 + 标题这类）。
  final Widget? titleWidget;

  /// 标题样式，默认 [AppText.dialogTitle]。
  final TextStyle? titleStyle;

  /// 标题对齐方式。目录选择器这类"返回 + 居中标题 + 关闭"的行用 center。
  final TextAlign titleAlign;

  /// 标题下方的一句说明，随内容一起滚（不参与标题行的固定高度）。
  final Widget? subtitle;

  /// 标题行左侧动作（「上一级」）。不传就不占位。
  final Widget? leading;

  /// 标题行右侧动作。不传 = 默认的关闭钮。
  final Widget? titleTrailing;

  final Widget? child;

  /// 底部动作区（贴在内容下方、不参与滚动）。
  final Widget? actions;

  /// 固定尺寸：给了就按它撑开（设置浮层用），否则用 [maxWidth] / [maxHeight]。
  final double? width;
  final double? height;

  final double maxWidth;
  final double? maxHeight;

  final EdgeInsets insetPadding;

  /// 滚动内容的内边距。`scrollable: false` 时由调用方自己掌握。
  final EdgeInsetsGeometry contentPadding;

  /// 内容是否由外壳包一层滚动。固定布局（左右分栏、列表 + 底栏）传 false。
  final bool scrollable;

  /// 关闭回调。不传时 `Navigator.maybePop()`；要带返回值（如 `pop(false)`）就自己给。
  final VoidCallback? onClose;

  final Key? closeKey;
  final String closeTooltip;

  final ShapeBorder? shape;
  final Clip clipBehavior;

  void _close(BuildContext context) {
    final close = onClose;
    if (close != null) {
      close();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _titleBar(context),
        Flexible(child: _content()),
        ?actions,
      ],
    );

    final sized = width != null || height != null
        ? SizedBox(key: panelKey, width: width, height: height, child: body)
        : ConstrainedBox(
            key: panelKey,
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight ?? double.infinity,
            ),
            child: body,
          );

    return Dialog(
      key: dialogKey,
      insetPadding: insetPadding,
      // 底色是组件的视觉契约，不给调用方覆盖，按亮度分档：
      // - 浅色：与页面同色（`surface`），层级交给遮罩与圆角；
      // - 深色：抬到 `surfaceContainerHigh`。页面底在深色下接近纯黑，同色时弹窗
      //   与背景只剩遮罩压出来的一点点差（约 1.07:1），必须"比其他容器亮一档"
      //   才看得出浮层——这也是 M3 在深色里表达 elevation 的做法。
      backgroundColor: scheme.brightness == Brightness.dark
          ? scheme.surfaceContainerHigh
          : scheme.surface,
      clipBehavior: clipBehavior,
      shape:
          shape ??
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
      child: CallbackShortcuts(
        // `DialogRoute` 自带 Esc → pop，但焦点落在某些输入框上时会先被吃掉；
        // 这一层兜底，保证任何位置按 Esc 都能关。
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _close(context),
        },
        child: Focus(autofocus: true, child: sized),
      ),
    );
  }

  Widget _titleBar(BuildContext context) {
    final style = titleStyle ?? AppText.of(context).dialogTitle;

    return SizedBox(
      height: kAppDialogTitleBarHeight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          leading == null
              ? kAppDialogTitleStartInset
              : kAppDialogTitleStartInsetWithLeading,
          0,
          kAppDialogEndInset,
          0,
        ),
        child: Row(
          children: <Widget>[
            ?leading,
            Expanded(
              child:
                  titleWidget ??
                  Text(
                    title!,
                    textAlign: titleAlign,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
            ),
            titleTrailing ?? _closeButton(context),
          ],
        ),
      ),
    );
  }

  Widget _closeButton(BuildContext context) {
    return IconButton(
      key: closeKey,
      tooltip: closeTooltip,
      onPressed: () => _close(context),
      style: kAppDialogIconButtonStyle,
      icon: const Icon(Icons.close_rounded, size: 20),
    );
  }

  Widget _content() {
    final body = child ?? const SizedBox.shrink();
    if (!scrollable) {
      return body;
    }

    return SingleChildScrollView(
      padding: contentPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (subtitle != null) ...<Widget>[
            subtitle!,
            const SizedBox(height: 18),
          ],
          body,
        ],
      ),
    );
  }
}
