/// 右栏浏览器的页面缩放梯度。
///
/// 与 Chrome 的页面缩放一致（25% ~ 500%）：低档密、高档疏，100% 两侧各留
/// 一档"微调"，从 200% 往上跨度拉大——再细的档位没人分辨得出，只会让连点
/// 十几次才到目标。两端不循环：到 25% 再点「缩小」、到 500% 再点「放大」
/// 都什么都不做，而不是瞬间跳回另一头。
const List<double> kBrowserZoomLadder = <double>[
  0.25,
  0.33,
  0.50,
  0.67,
  0.75,
  0.80,
  0.90,
  1.00,
  1.10,
  1.25,
  1.50,
  1.75,
  2.00,
  2.50,
  3.00,
  4.00,
  5.00,
];

/// 允许的最小 / 最大比例。JS 分支自己也会夹一次，这里只是给状态层一个口径。
const double kBrowserZoomMin = 0.25;
const double kBrowserZoomMax = 5.00;

/// 原生快捷键发回来的缩放动作。
///
/// 原生侧只负责"这个组合键属于浏览器缩放"，具体是放大还是缩小由键位决定；
/// 真正改哪一份状态留在 Dart，和工具条按钮走同一条出口。
enum BrowserZoomCommand {
  zoomIn('in'),
  zoomOut('out'),
  reset('reset');

  const BrowserZoomCommand(this.wireName);

  /// `personal_agent/window` 通道里 `action` 字段的取值。
  final String wireName;

  /// 把通道里的字符串还原成命令；认不出返回 null（新版本原生 + 旧 Dart 时不崩）。
  static BrowserZoomCommand? fromWire(Object? raw) {
    for (final command in values) {
      if (command.wireName == raw) {
        return command;
      }
    }
    return null;
  }
}

/// 当前比例与档位之间的容差。
///
/// 比例来自 `pageZoom` 的 double，`0.9` 这类值经一次乘除就可能变成
/// `0.8999999`；不留容差会让"当前档位"判定失败，表现为点一下跳两档。
const double _kZoomEpsilon = 0.005;

/// 比 [zoom] 大的下一档；已在顶端（或不在档位上且没有更高档）时返回 null。
double? nextBrowserZoom(double zoom) {
  for (final step in kBrowserZoomLadder) {
    if (step > zoom + _kZoomEpsilon) {
      return step;
    }
  }
  return null;
}

/// 比 [zoom] 小的上一档；已在底端时返回 null。
double? previousBrowserZoom(double zoom) {
  for (var i = kBrowserZoomLadder.length - 1; i >= 0; i--) {
    final step = kBrowserZoomLadder[i];
    if (step < zoom - _kZoomEpsilon) {
      return step;
    }
  }
  return null;
}

/// 浮层里显示的比例文案：`110%`。
///
/// 不四舍五入到档位：比例若来自页面自身（或将来允许输入），显示值必须和
/// 眼前内容一致；写死档位只会让人以为缩放没生效。
String browserZoomLabel(double zoom) {
  final percent = (zoom * 100).round();
  return '$percent%';
}

/// 非 Apple 平台的缩放脚本。
///
/// Android / Windows 的插件没有暴露缩放因子，只能注入 CSS：Apple 文档对
/// `WKWebView.pageZoom` 的说明就是"等价于给全部页面内容设置 CSS zoom"，
/// 两条路的效果同源。100% 时清掉内联样式，把 `zoom` 交回页面自己（样式表
/// 里可能有站点自带的 zoom）；否则写入绝对百分比，重复执行也不会叠加。
String zoomScript(double zoom) {
  final clamped = zoom.clamp(kBrowserZoomMin, kBrowserZoomMax);
  if ((clamped - 1).abs() < 0.0001) {
    return "document.documentElement.style.removeProperty('zoom');";
  }
  final percent = (clamped * 100).round();
  return "document.documentElement.style.zoom = '$percent%';";
}
