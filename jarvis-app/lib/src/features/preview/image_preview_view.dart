import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import 'pan_cursor_area.dart';
import 'preview_toolbar.dart';
import 'zoom_ladder.dart';

/// 图片查看器：拖动平移、滚动/捏合缩放、双击在 1× 与 2.5× 之间切换。
///
/// 刻意不用 WebView：`Image` 走 GPU 解码、内存更省，手势也完全归我们控制
/// （WebView 里连"双击回到适应窗口"都得靠注入 JS）。
///
/// 只接收字节，不读 provider：面板与全屏页共用同一个组件，
/// 数据来源由外面决定，组件本身不该知道"项目"这回事。
class ImagePreviewView extends StatefulWidget {
  const ImagePreviewView({super.key, required this.path, required this.bytes});

  /// 文件路径，只用于"换了文件就复位视图"以及错误提示。
  final String path;

  final Uint8List bytes;

  @override
  State<ImagePreviewView> createState() => _ImagePreviewViewState();
}

class _ImagePreviewViewState extends State<ImagePreviewView>
    with SingleTickerProviderStateMixin {
  /// 1× = 适应窗口。再往下缩只会得到一圈空白边框，没有意义。
  static const double _minScale = 1;
  static const double _maxScale = 8;
  static const double _doubleTapScale = 2.5;

  /// 图片可视区（不含底栏）的 Key：缩放中心要按它算，不能用整个 Column 的尺寸。
  final GlobalKey _viewportKey = GlobalKey();

  final TransformationController _controller = TransformationController();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  Animation<Matrix4>? _tween;

  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// 图片原始像素尺寸；解码失败前为 null。
  Size? _imageSize;

  /// 双击落点（视口坐标），用于让缩放锚在手指/鼠标处。
  Offset _doubleTapPosition = Offset.zero;

  /// 当前是否拖得动（放大过才有可平移的余量）。
  ///
  /// 只在跨过阈值时 setState：控制器每帧都在变，逐帧重建整棵查看器
  /// 会让缩放动画掉帧。
  bool _pannable = false;

  @override
  void initState() {
    super.initState();
    _animation.addListener(() {
      final tween = _tween;
      if (tween != null) {
        _controller.value = tween.value;
      }
    });
    _controller.addListener(_syncPannable);
  }

  void _syncPannable() {
    final pannable = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (pannable != _pannable && mounted) {
      setState(() => _pannable = pannable);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImageSize();
  }

  @override
  void didUpdateWidget(covariant ImagePreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      // 同一个标签换文件（预览标签按路径开，正常不会发生，但复用组件时要有兜底）：
      // 视图必须回到"适应窗口"，否则用户会以为新图被裁掉了一块。
      _controller.value = Matrix4.identity();
      _syncPannable();
      _imageSize = null;
      _resolveImageSize();
    }
  }

  @override
  void dispose() {
    _removeImageListener();
    _controller.removeListener(_syncPannable);
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 单独解析一次图片流，只为拿原始尺寸显示在底栏。
  ///
  /// 不复用 `Image` 内部的解析：那条路拿不到 `ImageInfo`；这里多一次解码，
  /// 但 Flutter 的 `ImageCache` 会命中同一份字节，实际不会再解一遍。
  void _resolveImageSize() {
    _removeImageListener();
    final stream = MemoryImage(widget.bytes)
        .resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!mounted) {
          return;
        }
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        if (_imageSize != size) {
          setState(() => _imageSize = size);
        }
        stream.removeListener(listener);
      },
      onError: (error, stackTrace) {
        // 解码失败交给 `Image` 的 errorBuilder 呈现，这里只是别再等着尺寸。
        stream.removeListener(listener);
      },
    );
    _listener = listener;
    _stream = stream;
    stream.addListener(listener);
  }

  void _removeImageListener() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  double get _scale => _controller.value.getMaxScaleOnAxis();

  /// 以 [focal]（视口坐标）为不动点缩放。
  ///
  /// 数学上是 `T(focal) · S(ratio) · T(-focal) · M`：焦点处的内容在屏幕上不动，
  /// 这才是"放大我正在看的那一块"，而不是围着视口中心放大。
  Matrix4 _matrixFor(Offset focal, double targetScale) {
    final current = _scale;
    final clamped = targetScale.clamp(_minScale, _maxScale);
    if ((clamped - current).abs() < 0.001) {
      return _controller.value;
    }
    final ratio = clamped / current;
    return Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(ratio, ratio, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1)
      ..multiply(_controller.value);
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(
      begin: _controller.value,
      end: target,
    ).animate(CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic));
    _animation.forward(from: 0);
  }

  Size? get _viewportSize {
    final box = _viewportKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : null;
  }

  void _zoomBy(double factor, {Offset? focal}) {
    final viewport = _viewportSize;
    final center =
        focal ??
        (viewport == null
            ? Offset.zero
            : Offset(viewport.width / 2, viewport.height / 2));
    _animateTo(_matrixFor(center, _scale * factor));
  }

  /// 双击：已经放大过就回到适应窗口，否则放大到 2.5×。
  void _handleDoubleTap() {
    _animateTo(
      _scale > 1.05
          ? Matrix4.identity()
          : _matrixFor(_doubleTapPosition, _doubleTapScale),
    );
  }

  /// 鼠标滚轮 / 触控板双指：以指针为锚点缩放。
  ///
  /// `InteractiveViewer` 默认只处理捏合与拖动，桌面滚轮要靠这个显式接管。
  /// 用指数而不是线性：滚得越快缩得越多，但永远不会"一步到底"。
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final factor = math.exp(-event.scrollDelta.dy / 320);
    _zoomBy(factor, focal: event.localPosition);
  }

  /// 适应窗口：回到单位矩阵，即初始的 contain 视图。
  void _fit() => _animateTo(Matrix4.identity());

  /// 按钮：跳到下一个/上一个固定档位。
  ///
  /// [target] 为 null 表示已经到两端——此时什么都不做，绝不回环：
  /// 从 800% 一下跳回 100% 会让人以为点了"适应窗口"。
  void _zoomToStep(double? target) {
    if (target == null) {
      return;
    }
    final next = target.clamp(_minScale, _maxScale);
    // 100% 以下的两档（PDF 用来缩到半页）在这里会被裁回 1×：
    // 与当前值相同时直接返回，免得空跑一段 160ms 的动画。
    if ((next - _scale).abs() < 0.001) {
      return;
    }
    final viewport = _viewportSize;
    final center = viewport == null
        ? Offset.zero
        : Offset(viewport.width / 2, viewport.height / 2);
    _animateTo(_matrixFor(center, next));
  }

  /// 实际大小：让 1 个图片像素约占 1 个逻辑像素。
  ///
  /// 图片比视口大时这是放大；比视口小时按 1× 显示（不把缩略图放糊）。
  void _actualSize() {
    final viewport = _viewportSize;
    final image = _imageSize;
    if (viewport == null || image == null || image.isEmpty) {
      _fit();
      return;
    }
    final fit = math.min(
      viewport.width / image.width,
      viewport.height / image.height,
    );
    if (fit >= 1) {
      _fit();
      return;
    }
    _animateTo(
      _matrixFor(Offset(viewport.width / 2, viewport.height / 2), 1 / fit),
    );
  }

  String? get _info {
    final image = _imageSize;
    final parts = <String>[
      if (image != null) '${image.width.round()}×${image.height.round()}',
      formatFileSize(widget.bytes.length),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Listener(
            key: _viewportKey,
            onPointerSignal: _handlePointerSignal,
            child: GestureDetector(
              // 视口空白处双击也要能归位：手势挂在整块区域上，
              // 而不是只挂在图片那一层（图片 contain 后四周有留白）。
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: (details) =>
                  _doubleTapPosition = details.localPosition,
              onDoubleTap: _handleDoubleTap,
              // 放大后内容才拖得动：只有这时才把光标换成抓手，
              // 适应窗口时整屏都是抓手会让人以为拖动有反应。
              child: PanCursorArea(
                enabled: _pannable,
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: _minScale,
                  maxScale: _maxScale,
                  // 图片 contain 后四周本就留白；给一点边界余量，
                  // 放大时可以把边缘的内容拖到视口中间。
                  boundaryMargin: const EdgeInsets.all(80),
                  // 适应窗口时关掉平移：`boundaryMargin` 会让内容在 1× 下
                  // 也能拖动几十像素，于是出现"图动了、光标却没变成抓手"
                  // 的错位。能不能拖、光标长什么样必须是同一个判据。
                  panEnabled: _pannable,
                  child: SizedBox.expand(
                    child: Image.memory(
                      widget.bytes,
                      fit: BoxFit.contain,
                      // 同一个标签内重建（主题切换等）不要重新淡入。
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '图片解码失败，可能已损坏或不是受支持的格式',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: AppFontSize.sm,
                              height: AppLineHeight.relaxed,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 缩放百分比必须跟着控制器刷新：`InteractiveViewer` 的矩阵变化不会
        // 触发本组件的 setState，不监听就永远停在 100%。
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => PreviewToolbar(
            info: _info,
            zoomPercent: zoomPercentOf(_scale),
            // 按钮走固定梯度；滚轮仍走 `_zoomBy` 的连续缩放——
            // 一个是"跳档"，一个是"微调"，本来就是两件事。
            onZoomIn: () => _zoomToStep(nextZoomStep(_scale)),
            onZoomOut: () => _zoomToStep(previousZoomStep(_scale)),
            onFit: _fit,
            onActualSize: _actualSize,
          ),
        ),
      ],
    );
  }
}
