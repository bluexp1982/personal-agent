import 'package:flutter/material.dart';

/// 栏头 / 工具条图标按钮悬停底的圆角。
///
/// 与标签、列表行、地址框同值（8）：这一类的视觉是一个"贴着栏的方块"，
/// 用 Material 默认的 `StadiumBorder` 在 24–28dp 的命中区里等于一个正圆，
/// 与本栏里那些 8dp 圆角的标签放在同一行会显得不是一套。
const double kShellIconButtonRadius = 8;

/// 上面那档圆角对应的边长：8 圆角配 24 见方，是这类按钮的基准比例（1 : 3）。
///
/// 与 `features/shell` 的 `kPaneHeaderButtonSize` 是同一个设计事实，但 `core`
/// 不能反向依赖 `features`，所以基准在这里再存一份；换成别的尺寸时用
/// [shellIconButtonRadiusFor] 等比换算，别手写圆角。
const double kShellIconButtonBaseSize = 24;

/// 按边长等比换算悬停底圆角：24 见方 → 8，16 见方 → 5.33，36 见方 → 12。
///
/// 大批按钮（弹窗关闭钮这类比栏头大一号的）靠它继续保持"同一个形状"，而不是
/// 把小方块上的 8 直接搬过去——那会显得更方。
double shellIconButtonRadiusFor(double size) =>
    kShellIconButtonRadius * size / kShellIconButtonBaseSize;

/// 只换轮廓、不动尺寸：给那些自己已经定好命中区的按钮用。
///
/// 与 [shellIconButtonStyle] 的区别是它不碰 `minimumSize` / `padding` /
/// `tapTargetSize`，所以栏头行里那枚默认 40 见方的「…」不会因为改圆角
/// 就顺带缩水、把整行的间距带跑。
///
/// 不放进全局 `iconButtonTheme`：输入栏的发送键、消息复制键本来就该是圆形，
/// 一个全局形状会把它们一起磨方。未列出的 `IconButton` 仍走默认圆形。
///
/// `shape` 用 `copyWith` 补而不是塞进 `IconButton.styleFrom`：后者的 `shape`
/// 参数在不同 Flutter 版本上并不一致，`copyWith` 是稳定路径。
/// [radius] 只在命中区明显小于 24 时才需要调小：8 的圆角套在 16 见方的块上
/// 已经接近正圆，缩到 5 才能继续保持"圆角方形"的观感。
ButtonStyle shellIconButtonShape({double radius = kShellIconButtonRadius}) {
  return ButtonStyle().copyWith(
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
    ),
  );
}

/// 栏头 / 工具条图标按钮的统一样式。
///
/// 只负责形状与紧凑度（圆角方形 + 零内边距 + 收缩命中区），颜色一律留给
/// 主题：悬停灰、禁用态、前景色沿用它，调色板改动时这里不用跟着改。
ButtonStyle shellIconButtonStyle({
  Size? minimumSize,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  double radius = kShellIconButtonRadius,
}) {
  return IconButton.styleFrom(
    minimumSize: minimumSize,
    padding: padding,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  ).merge(shellIconButtonShape(radius: radius));
}
