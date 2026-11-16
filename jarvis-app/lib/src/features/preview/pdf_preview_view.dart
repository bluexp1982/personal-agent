import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../core/design/app_palette.dart';
import '../../core/design/app_tokens.dart';
import '../../core/models.dart';
import 'pan_cursor_area.dart';
import 'preview_toolbar.dart';
import 'zoom_ladder.dart';

/// PDF 查看器（PDFium）。
///
/// 为什么是 pdfrx 而不是 WebView + pdf.js：Android 的 WebView 没有 PDF 渲染器，
/// 三端一致的唯一方案是自带引擎；而 pdf.js 还要 1.5 MB 资源与 Range 支持，
/// Linux 上更是连 WebView 都没有。pdfrx 直接吃内存字节，缩放、滚动、选字都由库给。
///
/// 只接收字节，不读 provider：面板与全屏页共用，数据来源由外面决定。
class PdfPreviewView extends StatefulWidget {
  const PdfPreviewView({super.key, required this.path, required this.bytes});

  /// 文件路径。既用来当文档的 `sourceName`（pdfrx 要求每个来源唯一），
  /// 也用于错误提示里指明是哪一份文件。
  final String path;

  final Uint8List bytes;

  @override
  State<PdfPreviewView> createState() => _PdfPreviewViewState();
}

class _PdfPreviewViewState extends State<PdfPreviewView> {
  final PdfViewerController _controller = PdfViewerController();

  /// 当前页，由 `onPageChanged` 回填。1-based。
  int? _page;

  /// 总页数，文档就绪后才有值。
  int _pageCount = 0;

  void _goToPage(int page) {
    if (_pageCount <= 0) {
      return;
    }
    final target = page.clamp(1, _pageCount);
    // 翻页动画交给库：自己算滚动偏移会在双页/横向布局下算错。
    _controller.goToPage(pageNumber: target);
  }

  /// 「适应窗口」的绝对缩放值（整页装下）。
  ///
  /// 用 `alternativeFitScale`（fit-page）而不是 `minScale`：后者是"允许缩到多小"
  /// 的下限 0.5，在宽屏上会把整页缩得比视口还小。两条都拿不到时退回
  /// `coverScale`，至少不会拿 0 去做除法。
  double? get _fitZoom {
    if (!_controller.isReady) {
      return null;
    }
    return _controller.alternativeFitScale ?? _controller.coverScale;
  }

  /// 按钮：按固定梯度跳一档（相对适应窗口）。
  ///
  /// 不走 pdfrx 的 `zoomUp/zoomDown`：它的默认停靠点是「fit-page、fit-width
  /// 两个结构点 + 2 的幂」，一次点击会从 103% 直接跳到 239%
  /// （fit-page → fit-width）。这里自己算目标，到两端就停住、不回环。
  void _zoomToStep({required bool up}) {
    final fit = _fitZoom;
    if (fit == null || fit <= 0) {
      return;
    }
    final relative = _controller.currentZoom / fit;
    final target = up ? nextZoomStep(relative) : previousZoomStep(relative);
    if (target == null) {
      return;
    }
    _setZoomTo(fit * target);
  }

  /// 统一的缩放入口：未就绪时直接忽略。
  ///
  /// pdfrx 的 `setZoom` 内部要读 `_viewSize`，文档还没准备好时调用会抛空指针；
  /// 底栏按钮在加载态也是可点的，必须在这里拦住。
  void _setZoomTo(double zoom) {
    if (!_controller.isReady) {
      return;
    }
    final next = zoom.clamp(_controller.minScale, _controller.maxScale);
    // 与当前值相同就别动：一路按到顶/底时，按钮保持沉默比反复触发动画好。
    if ((next - _controller.currentZoom).abs() < 1e-6) {
      return;
    }
    _controller.setZoom(_viewCenter, next);
  }

  Offset get _viewCenter =>
      _controller.isReady ? _controller.viewSize.center(Offset.zero) : Offset.zero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);

    // 页底色比正文底浅一档：PDF 页面自带白底，纯白贴在深色主题上会像一块灯箱。
    final pageBackground = scheme.surfaceContainerHighest.withValues(
      alpha: 0.45,
    );

    return Column(
      children: <Widget>[
        Expanded(
          // PDF 里拖动就是平移（放大后拖、翻页靠滚动），光标统一给抓手；
          // 文字区域上 pdfrx 自己会换成文本光标，内层 MouseRegion 优先。
          child: PanCursorArea(
            child: PdfViewer.data(
              widget.bytes,
              sourceName: widget.path,
              controller: _controller,
              params: PdfViewerParams(
                backgroundColor: pageBackground,
                margin: 10,
                // 与文本预览对齐：能选、能复制。
                textSelectionParams: const PdfTextSelectionParams(),
                // 8× 是"看清一张扫描件上的小字"的够用量级；下限 0.5 防止整份
                // 文档缩成一条线。关掉 alternativeFitScale：几百页的文档
                // 若按"最小缩放=整份装下"来算，会一次性渲染大量页面。
                sizeDelegateProvider: const PdfViewerSizeDelegateProviderLegacy(
                  maxScale: 8,
                  minScale: 0.5,
                  useAlternativeFitScaleAsMinScale: false,
                ),
                // 双击与键盘缩放也走同一套梯度，否则底栏按档位、双击按
                // pdfrx 默认的「fit-page → fit-width → 2 的幂」，同一界面两种节奏。
                zoomStepsDelegateProvider: const LadderZoomStepsProvider(),
                onViewerReady: (document, controller) {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _pageCount = document.pages.length;
                    _page ??= 1;
                  });
                },
                onPageChanged: (pageNumber) {
                  if (!mounted || pageNumber == null || pageNumber == _page) {
                    return;
                  }
                  setState(() => _page = pageNumber);
                },
                loadingBannerBuilder: (context, bytesDownloaded, totalBytes) =>
                    Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.text.tertiary,
                        ),
                      ),
                    ),
                errorBannerBuilder: (context, error, stackTrace, documentRef) {
                  final encrypted = error is PdfPasswordException;
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            encrypted
                                ? Icons.lock_outline_rounded
                                : Icons.picture_as_pdf_outlined,
                            size: 26,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            encrypted
                                ? '文档已加密，暂不支持在这里输入密码；可另存到本机用系统应用打开'
                                : 'PDF 打开失败，可能已损坏或不是有效的 PDF 文件',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: AppFontSize.sm,
                              height: AppLineHeight.relaxed,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        // 页码与缩放都跟着控制器刷新：滚动、捏合、键盘操作都会改它。
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final fit = _fitZoom;
            // 百分比相对"适应窗口"：静止就是 100%，和图片查看器同一口径。
            // 以前显示的是绝对 zoom（1.03 起步、fit-width 239%），
            // 用户会以为"100% 是原图大小"，其实那是库的内部刻度。
            final zoom = fit == null || fit <= 0
                ? 100
                : zoomPercentOf(_controller.currentZoom / fit);
            final page = _page ?? 1;
            return PreviewToolbar(
              info: formatFileSize(widget.bytes.length),
              zoomPercent: zoom,
              onZoomIn: () => _zoomToStep(up: true),
              onZoomOut: () => _zoomToStep(up: false),
              onFit: () => _setZoomTo(fit ?? 1),
              onActualSize: () => _setZoomTo(1),
              pageLabel: _pageCount > 0 ? '第 $page / $_pageCount 页' : null,
              onPreviousPage: _pageCount > 0 ? () => _goToPage(page - 1) : null,
              onNextPage: _pageCount > 0 ? () => _goToPage(page + 1) : null,
            );
          },
        ),
      ],
    );
  }
}
