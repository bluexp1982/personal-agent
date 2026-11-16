import 'package:pdfrx/pdfrx.dart';

/// 图片与 PDF 查看器共用的缩放梯度。
///
/// 相对「适应窗口」，1.0 即 100%。刻意做成固定档位而不是"乘 1.25"：
/// 乘法档位越往上越粗（100 → 125 → 156 → 195），同一颗按钮在 300% 附近
/// 一下就跳掉一屏；固定档位让每一档的观感一致，也方便用户记住"点到 200% 了"。
///
/// 100% 以下两档是给 PDF 用的（缩到半页能一次看到两页）。图片查看器的最小
/// 缩放是"适应窗口"，会把这两档裁掉，所以它按到 100% 就不会再变小。
///
/// 顶端 8.0 与 pdfrx 的 `maxScale: 8` 对齐：再高没有可渲染的细节，只是把
/// 扫描件的噪点放大。
const List<double> kZoomLadder = <double>[
  0.5,
  0.75,
  1.0,
  1.25,
  1.5,
  1.75,
  2.0,
  2.5,
  3.0,
  4.0,
  5.0,
  6.0,
  8.0,
];

/// 判定"正好落在档位上"的容差。
///
/// 滚轮可以停在 1.0301 这类值上，浮点误差会让"本来就是 125%"被判成不在档位，
/// 点一下直接跳到 150%——用一个远小于档距的容差吸收掉。
const double _epsilon = 0.005;

/// 比 [zoom] 大的下一档；已在顶端时返回 null（**不**回环到最小档）。
double? nextZoomStep(double zoom) {
  for (final step in kZoomLadder) {
    if (step > zoom + _epsilon) {
      return step;
    }
  }
  return null;
}

/// 比 [zoom] 小的上一档；已在底端时返回 null。
double? previousZoomStep(double zoom) {
  for (var i = kZoomLadder.length - 1; i >= 0; i--) {
    final step = kZoomLadder[i];
    if (step < zoom - _epsilon) {
      return step;
    }
  }
  return null;
}

/// 相对缩放 → 底栏显示的整数百分比。
///
/// 不在档位上也照实显示（滚轮停在 137% 就写 137）：显示值必须和眼前内容一致，
/// 四舍五入到档位只会让人以为滚轮失灵。
int zoomPercentOf(double relativeZoom) {
  if (!relativeZoom.isFinite || relativeZoom <= 0) {
    return 100;
  }
  return (relativeZoom * 100).round();
}

/// 给 pdfrx 用的绝对停靠点（双击 / 键盘缩放也走它）。
///
/// pdfrx 默认按「fit-page、fit-width 两个结构点 + 2 的幂」铺点，
/// 于是一次 `zoomUp` 可能从"整页装下"直接跳到"铺满宽度"。
/// 这里改成 fit × 我们的梯度，裁到库自己的 [min] / [max] 之间。
List<double> zoomStopsFor({
  required double fit,
  required double min,
  required double max,
}) {
  if (!fit.isFinite || fit <= 0 || !max.isFinite || max <= 0) {
    return <double>[if (min.isFinite && min > 0) min else 1.0, max];
  }
  final lower = min.isFinite && min > 0 ? min : fit;
  final upper = max < fit ? fit : max;

  final stops = <double>{
    for (final step in kZoomLadder)
      if (fit * step >= lower - _epsilon && fit * step <= upper + _epsilon)
        fit * step,
  }.toList()..sort();

  // 两端补齐：库的 min / max 也是合法停靠点，缺了会让"缩到底"停在半路。
  // 先判重：梯度里本来就有 0.5 时，直接 insert 会得到两个一模一样的停靠点。
  if (stops.isEmpty || !_almostSame(stops.first, lower)) {
    stops.insert(0, lower);
  }
  if (!_almostSame(stops.last, upper)) {
    stops.add(upper);
  }
  return stops;
}

bool _almostSame(double a, double b) => (a - b).abs() < 1e-6;

/// pdfrx 停靠点委托：把库的默认节奏换成 [kZoomLadder]。
///
/// 必须是 `const` 且实现 `==`：`PdfViewerParams` 用相等判断决定要不要重建，
/// 每次 build 新建一个不相等的 provider 会让文档被反复打开。
class LadderZoomStepsProvider extends PdfViewerZoomStepsDelegateProvider {
  const LadderZoomStepsProvider();

  @override
  PdfViewerZoomStepsDelegate create() => const _LadderZoomStepsDelegate();

  @override
  bool operator ==(Object other) => other is LadderZoomStepsProvider;

  @override
  int get hashCode => runtimeType.hashCode;
}

class _LadderZoomStepsDelegate implements PdfViewerZoomStepsDelegate {
  const _LadderZoomStepsDelegate();

  @override
  void dispose() {}

  @override
  List<double> generateZoomStops(PdfViewerLayoutMetrics metrics) {
    // `alternativeFitScale` 是"整页装下"，`coverScale` 是"铺满宽度"。
    // 有前者就以它为 100%，两者相同时（版面正好等比）退回 cover。
    final fit = metrics.alternativeFitScale ?? metrics.coverScale;
    return zoomStopsFor(
      fit: fit,
      min: metrics.minScale,
      max: metrics.maxScale,
    );
  }
}
