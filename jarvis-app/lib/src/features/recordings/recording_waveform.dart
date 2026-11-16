import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 录音波形。只用自绘：柱距、圆角与静音时的中轴线都要跟着状态色走，
/// 用现成的图表库反而要为这三个参数写一堆配置。
///
/// 同一组件既画录音页的大波形（高度 72），也画迷你状态条上的 5 根柱子
/// （高度 16）：两者只差槽位数与柱宽，视觉曲线必须完全一致。
class RecordingWaveform extends StatelessWidget {
  const RecordingWaveform({
    super.key,
    required this.levels,
    required this.color,
    this.height = 72,
    this.active = true,
    this.slots,
    this.barWidth,
  });

  /// 槽位数下限：再窄也要保证波形看起来是"一串柱子"。
  static const int minSlots = 32;

  /// 槽位数上限：与 controller 的电平历史上限一致，多了没有数据可画。
  static const int maxSlots = 96;

  /// 最近若干次采样的电平（0..1），越靠右越新。
  final List<double> levels;
  final Color color;
  final double height;
  final bool active;

  /// 固定槽位数（迷你条传 5）；为 null 时按可用宽度自适应。
  final int? slots;

  /// 柱宽；为 null 时取 3（录音页大波形的既有口径）。
  final double? barWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaveformPainter(
          levels: levels,
          color: color,
          active: active,
          slots: slots,
          barWidth: barWidth,
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.levels,
    required this.color,
    required this.active,
    this.slots,
    this.barWidth,
  });

  final List<double> levels;
  final Color color;
  final bool active;
  final int? slots;
  final double? barWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final bar = barWidth ?? 3;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = bar;

    if (!active || levels.isEmpty) {
      final idle = Paint()
        ..color = color.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2;
      canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), idle);
      return;
    }

    final slotCount = slots ?? _autoSlots(size.width, bar);
    // 柱宽固定、间距吃掉剩余宽度：宽度不够时柱子会自然靠拢，
    // 不会出现"柱子比槽位还宽"的绘制溢出。
    final gap = slotCount <= 1
        ? 0.0
        : math.max(0.0, (size.width - slotCount * bar) / (slotCount - 1));
    final step = bar + gap;
    final startIndex = slotCount - levels.length;

    for (var slot = 0; slot < slotCount; slot++) {
      final index = slot - startIndex;
      final level = index >= 0 && index < levels.length
          ? levels[index].clamp(0.0, 1.0)
          : 0.0;
      // 轻声也要看得见：最小高度之外再按电平开方，视觉上更接近人耳。
      final amplitude = 3 + math.sqrt(level) * (size.height / 2 - 4);
      final x = bar / 2 + slot * step;
      final top = centerY - amplitude;
      final bottom = centerY + amplitude;
      final opacity = 0.35 + 0.65 * level;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
  }

  /// 按宽度反推槽位：相邻柱子的最小节距取两倍柱宽，再夹到 32~96。
  int _autoSlots(double width, double bar) {
    if (width <= 0) {
      return RecordingWaveform.minSlots;
    }
    final fit = (width / (bar * 2)).floor();
    return fit.clamp(RecordingWaveform.minSlots, RecordingWaveform.maxSlots);
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.levels != levels ||
      oldDelegate.color != color ||
      oldDelegate.active != active ||
      oldDelegate.slots != slots ||
      oldDelegate.barWidth != barWidth;
}
