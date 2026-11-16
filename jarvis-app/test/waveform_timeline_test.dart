import 'dart:typed_data';

import 'package:jarvis_app/src/core/recording/waveform_peaks.dart';
import 'package:jarvis_app/src/features/recordings/waveform_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double _width = 300;

Uint8List peaksOf(int value) =>
    Uint8List(kWaveformBuckets)..fillRange(0, kWaveformBuckets, value);

Widget host({
  Uint8List? peaks,
  ValueChanged<double>? onSeek,
  double progress = 0.25,
  Duration? duration = const Duration(seconds: 100),
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _width,
          child: WaveformTimeline(
            peaks: peaks,
            progress: progress,
            color: const Color(0xFF3B6EA5),
            onSeek: onSeek,
            duration: duration,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('点按波形按比例回调 seek', (tester) async {
    final calls = <double>[];
    await tester.pumpWidget(host(peaks: peaksOf(200), onSeek: calls.add));

    final rect = tester.getRect(find.byType(WaveformTimeline));
    await tester.tapAt(Offset(rect.left + _width * 0.5, rect.center.dy));
    await tester.pump();

    expect(calls, hasLength(1));
    expect(calls.single, closeTo(0.5, 0.02));
  });

  testWidgets('点在最左侧与最右侧分别夹到 0 与 1', (tester) async {
    final calls = <double>[];
    await tester.pumpWidget(host(peaks: peaksOf(200), onSeek: calls.add));
    final rect = tester.getRect(find.byType(WaveformTimeline));

    await tester.tapAt(Offset(rect.left, rect.center.dy));
    await tester.tapAt(Offset(rect.right - 0.5, rect.center.dy));
    await tester.pump();

    expect(calls.first, lessThanOrEqualTo(0.02));
    expect(calls.last, greaterThanOrEqualTo(0.98));
  });

  testWidgets('拖动时 60ms 节流：中间帧不发，松手补末值', (tester) async {
    final calls = <double>[];
    await tester.pumpWidget(host(peaks: peaksOf(200), onSeek: calls.add));
    final rect = tester.getRect(find.byType(WaveformTimeline));

    final gesture = await tester.startGesture(
      Offset(rect.left + 15, rect.center.dy),
    );
    await gesture.moveBy(const Offset(60, 0));
    await gesture.moveBy(const Offset(60, 0));
    await gesture.up();
    await tester.pump();

    expect(calls, hasLength(2));
    expect(calls.last, closeTo(0.45, 0.08));
  });

  testWidgets('peaks 为 null 时降级：不响应 seek', (tester) async {
    final calls = <double>[];
    await tester.pumpWidget(host(peaks: null, onSeek: calls.add));

    expect(find.byType(CustomPaint), findsWidgets);
    final rect = tester.getRect(find.byType(WaveformTimeline));
    await tester.tapAt(rect.center);
    await tester.pump();

    expect(calls, isEmpty);
  });

  testWidgets('带 slider 语义与百分比播报', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(peaks: peaksOf(200), onSeek: (_) {}));

    final node = tester.getSemantics(find.bySemanticsLabel('播放进度'));
    final data = node.getSemanticsData();
    expect(data.flagsCollection.isSlider, isTrue);
    expect(data.value, '25%');
    handle.dispose();
  });

  testWidgets('读屏加/减按 ±5 秒换算比例', (tester) async {
    final handle = tester.ensureSemantics();
    final calls = <double>[];
    await tester.pumpWidget(host(peaks: peaksOf(200), onSeek: calls.add));
    final finder = find.semantics.byLabel('播放进度');

    tester.semantics.increase(finder);
    await tester.pump();
    expect(calls.single, closeTo(0.30, 0.01));

    tester.semantics.decrease(finder);
    await tester.pump();
    expect(calls.last, closeTo(0.20, 0.01));
    handle.dispose();
  });
}
