import 'dart:typed_data' show Float64List;
import 'dart:ui' show FilterQuality, ImageFilter, Size;

/// 透镜放大倍率。
///
/// 1.10 是"看得出、又不像哈哈镜"的一档：61 高的胶囊上下各挪约 3pt、
/// 320 宽的胶囊左右各挪约 16pt，边缘和外面的内容出现错位——这正是水滴
/// 与普通磨砂玻璃的分界线。设成 1.0 即退回纯模糊（低端机或平台不生效时的降级）。
const double kNavLensScale = 1.14;

/// 透镜层内部的霜化量。
///
/// 必须比磨砂版本（18）轻得多：模糊一重，放大就被糊平，什么都看不出来。
/// 这一档只够让底下的字读不出来，形状与色带仍然完整。
const double kNavLensBlurSigma = 5;

/// 底部导航胶囊的 backdrop 滤镜：轻霜化 + 绕中心放大的透镜。
///
/// 为什么不是真折射：`BackdropFilter` 只吃 `ImageFilter`，采样不到"身后内容"
/// 做非均匀位移场。能做的是「先霜化、再整体放大」——背景在胶囊里变大、
/// 与胶囊外的同一块内容错位，这是水滴最关键的视觉线索；配合边缘倒角
/// （见 `NarrowTabGlassEdge`）就成型了。
///
/// 滤镜必须缓存：`ImageFilter` 背后是原生对象，每次 build 新建会在滚动时
/// 反复分配（与 `_topBarBlur`、虚化带的 `_fadeBlur` 同一条理由）。
class NarrowTabLens {
  NarrowTabLens._();

  /// 以 (宽, 高, 倍率, 霜化量) 为键复用滤镜。尺寸变化（横竖屏、分屏拖拽）
  /// 只会多出一条，不会无限增长。
  static final Map<(double, double, double, double), ImageFilter> _cache =
      <(double, double, double, double), ImageFilter>{};

  /// 取胶囊尺寸对应的滤镜。
  ///
  /// [scale] 与 [sigma] 只在测试与调参时显式传入，默认走上面两个常量。
  static ImageFilter filterFor(
    Size size, {
    double scale = kNavLensScale,
    double sigma = kNavLensBlurSigma,
  }) {
    final key = (size.width, size.height, scale, sigma);
    return _cache.putIfAbsent(key, () => _build(size, scale, sigma));
  }

  static ImageFilter _build(Size size, double scale, double sigma) {
    final frost = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    if (scale == 1 || size.isEmpty) {
      return frost;
    }

    // 绕中心缩放：x' = scale·x + cx(1−scale)。矩阵按列主序填，
    // 平移量落在 12/13，缩放落在 0/5。原点是被过滤层的左上角，
    // 不绕中心的话内容会整体往右下角跑。
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final matrix = Float64List(16);
    matrix[0] = scale;
    matrix[5] = scale;
    matrix[10] = 1;
    matrix[15] = 1;
    matrix[12] = cx * (1 - scale);
    matrix[13] = cy * (1 - scale);

    // `outer` 作用在 `inner` 的结果上：先霜化，再放大。
    return ImageFilter.compose(
      outer: ImageFilter.matrix(matrix, filterQuality: FilterQuality.low),
      inner: frost,
    );
  }
}
