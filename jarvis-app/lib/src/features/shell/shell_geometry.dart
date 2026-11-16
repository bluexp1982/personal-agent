import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'file_pane_state.dart';

/// 三栏（中栏 + 右栏）在某个视口下的宽度分配。
///
/// 抽成一个值类型是为了让**中栏宽度只有一个来源**：骨架要拿它算「聊天窗口停靠在
/// 哪儿」，`_WideContent` 要拿它摆中栏与右栏。两处各写一遍算术，迟早会差一两个
/// dp——聊天窗口就会比中栏窄一圈，左边露出一条不该存在的缝。
///
/// [centerLeft] 是相对窗口左缘的偏移（= 左栏连同它右侧拖动条占掉的宽度），
/// 停靠矩形直接用它当 `left`，不需要再去测量一次中栏的实际位置。
@immutable
class ShellColumns {
  const ShellColumns({
    required this.centerLeft,
    required this.availableWidth,
    required this.centerWidth,
    required this.panelWidth,
  });

  /// 中栏左边界，等于左栏占用（含 8dp 拖动条）；左栏收起时为 0。
  final double centerLeft;

  /// 「中栏 + 拖动条 + 右栏」可用的总宽度（= 视口宽度 - [centerLeft]）。
  ///
  /// 面板宽度收敛要用它：拖动条算的是「这一栏能放到多宽」，分母必须是
  /// 去掉左栏之后的那块空间。
  final double availableWidth;

  /// 中栏可用宽度。面板全屏 / 终端与预览沉浸时为 0；画布沉浸时等于整块可用宽度。
  final double centerWidth;

  /// 右栏实际渲染宽度；收起、或窗口放不下它的最小宽度时为 0。
  final double panelWidth;

  /// 右栏与中栏之间那条拖动条是否要占位。
  ///
  /// 与 `_WideContent` 保持同一口径：面板收起之后拖动条压成 0 宽（只为留住手势），
  /// 不参与宽度分配。
  double get handleWidth => panelWidth > 0 ? kFilePaneHandleWidth : 0;

  @override
  bool operator ==(Object other) =>
      other is ShellColumns &&
      other.centerLeft == centerLeft &&
      other.availableWidth == availableWidth &&
      other.centerWidth == centerWidth &&
      other.panelWidth == panelWidth;

  @override
  int get hashCode =>
      Object.hash(centerLeft, availableWidth, centerWidth, panelWidth);
}

/// 按视口宽度与各栏状态算出中栏 / 右栏的宽度。
///
/// 与 `Row(children: [Expanded(中栏), 拖动条, SizedBox(右栏)])` 的分配结果严格一致：
/// `Expanded` 拿到的就是「可用宽度 - 拖动条 - 右栏」。所以这里算出来的
/// [ShellColumns.centerWidth] 可以当作中栏的实际宽度用，不需要 `GlobalKey` 测量、
/// 也不会因为测量晚一帧而抖动。
///
/// [fill] 是「右栏独占整块宽度」（面板全屏 / 终端与预览沉浸）：这时中栏让位
/// 成 0 宽，但**不写回**任何状态——退出全屏后仍按原来的宽度摆回来。
///
/// [centerFill] 是它的镜像：「中栏独占整块宽度」（画布沉浸），右栏与拖动条
/// 都收成 0。两者互斥，同时为真时按 [fill] 处理。
ShellColumns resolveShellColumns({
  required double viewportWidth,
  required double railTaken,
  required bool paneVisible,
  required double paneWidth,
  required bool fill,
  bool centerFill = false,
}) {
  final available = math.max(0.0, viewportWidth - railTaken);

  if (fill) {
    return ShellColumns(
      centerLeft: railTaken,
      availableWidth: available,
      centerWidth: 0,
      panelWidth: available,
    );
  }

  if (centerFill) {
    return ShellColumns(
      centerLeft: railTaken,
      availableWidth: available,
      centerWidth: available,
      panelWidth: 0,
    );
  }

  // 窗口不够宽时 `fitFilePaneWidth` 返回 0：整栏不渲染，也不把中栏挤成一条缝。
  final panel = paneVisible
      ? fitFilePaneWidth(width: paneWidth, available: available)
      : 0.0;
  final handle = panel > 0 ? kFilePaneHandleWidth : 0.0;

  return ShellColumns(
    centerLeft: railTaken,
    availableWidth: available,
    centerWidth: math.max(0.0, available - panel - handle),
    panelWidth: panel,
  );
}
