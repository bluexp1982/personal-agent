import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/recording/waveform_peaks.dart';

/// 整段音频的波形 + 播放进度 + 点击 seek。
///
/// 和录音时的 [RecordingWaveform] 分工明确：那个只画"最近几秒"的滚动电平，
/// 这个画"整段包络"并按进度着色。两者共用 [levelFromPeak] 的 dB 曲线，
/// 所以录的时候和回放的时候看起来是同一个东西。
///
/// 不画播放头竖线：已播/未播的颜色边界本身就是进度，多一根线只是噪声。
class WaveformTimeline extends StatefulWidget {
  const WaveformTimeline({
    super.key,
    required this.peaks,
    required this.progress,
    required this.color,
    this.height = 44,
    this.onSeek,
    this.duration,
  });

  /// `0..255` 峰值，长度不限；为 null 或空时降级为一条 28% 透明中线。
  final Uint8List? peaks;

  /// 音频时间的播放比例 `0..1`（不是录制时间轴）。
  final double progress;

  /// 已播部分的颜色；未播部分自动取同色 32% 透明。
  final Color color;

  final double height;

  /// 点击/拖动波形时回调比例；为 null 时只读。
  final ValueChanged<double>? onSeek;

  /// 读屏与键盘 ±5 秒步进需要总时长；缺省时只保留比例语义。
  final Duration? duration;

  /// 柱宽。整段波形固定细柱，宽度不够时按比例合并桶。
  static const double barWidth = 2;

  /// 拖动 seek 的节流间隔。
  static const Duration seekThrottle = Duration(milliseconds: 60);

  @override
  State<WaveformTimeline> createState() => _WaveformTimelineState();
}

class _WaveformTimelineState extends State<WaveformTimeline> {
  /// 归一化结果按 peaks 实例缓存：进度每帧都变，重新排序 480 个桶没有意义。
  Uint8List? _normalized;
  Uint8List? _normalizedFor;

  DateTime? _lastSeekAt;

  Uint8List? get _displayPeaks {
    final peaks = widget.peaks;
    if (identical(peaks, _normalizedFor)) {
      return _normalized;
    }
    _normalizedFor = peaks;
    _normalized = peaks == null || peaks.isEmpty ? null : normalizePeaks(peaks);
    return _normalized;
  }

  void _seekTo(double fraction, {bool force = false}) {
    final onSeek = widget.onSeek;
    if (onSeek == null) {
      return;
    }
    final now = DateTime.now();
    final last = _lastSeekAt;
    if (!force &&
        last != null &&
        now.difference(last) < WaveformTimeline.seekThrottle) {
      return;
    }
    _lastSeekAt = now;
    onSeek(fraction.clamp(0.0, 1.0));
  }

  String _percentLabel(double fraction) =>
      '${(fraction.clamp(0.0, 1.0) * 100).round()}%';

  void _seekBySeconds(double seconds) {
    final duration = widget.duration;
    if (duration == null || duration.inMilliseconds <= 0) {
      return;
    }
    _seekTo(
      widget.progress + seconds * 1000 / duration.inMilliseconds,
      force: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final peaks = _displayPeaks;
    final painter = _TimelinePainter(
      peaks: peaks,
      progress: widget.progress,
      color: widget.color,
      barWidth: WaveformTimeline.barWidth,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        Widget canvas = RepaintBoundary(
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: CustomPaint(painter: painter),
          ),
        );

        if (peaks == null) {
          // 降级：峰值还没算出来 / 接口失败 / 文件不可解析。画一条中线交给
          // 调用方保留原进度条，这里不吞手势。
          return canvas;
        }

        if (widget.onSeek != null && width.isFinite && width > 0) {
          canvas = MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) =>
                  _seekTo(details.localPosition.dx / width, force: true),
              onHorizontalDragStart: (details) =>
                  _seekTo(details.localPosition.dx / width, force: true),
              onHorizontalDragUpdate: (details) =>
                  _seekTo(details.localPosition.dx / width),
              onHorizontalDragEnd: (details) =>
                  _seekTo(details.localPosition.dx / width, force: true),
              child: canvas,
            ),
          );
        }

        final total = widget.duration?.inMilliseconds ?? 0;
        final stepFraction = total > 0 ? 5000 / total : 0.0;
        return Semantics(
          slider: true,
          label: '播放进度',
          value: _percentLabel(widget.progress),
          increasedValue: total > 0
              ? _percentLabel(widget.progress + stepFraction)
              : null,
          decreasedValue: total > 0
              ? _percentLabel(widget.progress - stepFraction)
              : null,
          onIncrease: total > 0 ? () => _seekBySeconds(5) : null,
          onDecrease: total > 0 ? () => _seekBySeconds(-5) : null,
          child: canvas,
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.peaks,
    required this.progress,
    required this.color,
    required this.barWidth,
  });

  final Uint8List? peaks;
  final double progress;
  final Color color;
  final double barWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    final buckets = peaks;
    if (buckets == null || buckets.isEmpty) {
      paint
        ..color = color.withValues(alpha: 0.28)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), paint);
      return;
    }

    // 宽度放不下所有桶时按比例合并取最大值：宁可少几根柱子，
    // 也不要柱子互相压成一块实色。
    final slotCount = math.min(
      buckets.length,
      math.max(1, (size.width / (barWidth + 1)).floor()),
    );
    final bucketsPerSlot = buckets.length / slotCount;
    final playedX = progress.clamp(0.0, 1.0) * size.width;
    final playedColor = color;
    final restColor = color.withValues(alpha: 0.32);
    final maxAmplitude = size.height / 2 - 1;

    for (var slot = 0; slot < slotCount; slot++) {
      final start = (slot * bucketsPerSlot).floor();
      final end = math.min(
        buckets.length,
        math.max(start + 1, ((slot + 1) * bucketsPerSlot).ceil()),
      );
      var peak = 0;
      for (var index = start; index < end; index++) {
        if (buckets[index] > peak) {
          peak = buckets[index];
        }
      }
      final level = levelFromPeak(peak);
      // 静音处留 1.5 个像素：整段波形始终有一条可读的基线。
      final amplitude = math.max(1.5, level * maxAmplitude);
      final x = (slot + 0.5) * size.width / slotCount;
      paint.color = x <= playedX ? playedColor : restColor;
      canvas.drawLine(
        Offset(x, centerY - amplitude),
        Offset(x, centerY + amplitude),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter oldDelegate) =>
      oldDelegate.peaks != peaks ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.barWidth != barWidth;
}
