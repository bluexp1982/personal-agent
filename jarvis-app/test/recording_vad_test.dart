import 'dart:typed_data';

import 'package:jarvis_app/src/core/recording/vad_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';

/// 320 个采样点（20ms），全部为同一个幅度。
Uint8List frame(int amplitude) {
  final data = ByteData(640);
  for (var index = 0; index < 320; index++) {
    data.setInt16(index * 2, amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('静音后收段，段首带预卷且时间戳与 PCM 对齐', () {
    final segments = <VadSegment>[];
    final segmenter = VadSegmenter(
      onSegment: segments.add,
      silenceMs: 200,
      minSegmentMs: 200,
      maxSegmentMs: 10000,
      prerollMs: 40,
    );

    for (var index = 0; index < 10; index++) {
      segmenter.add(frame(0));
    }
    for (var index = 0; index < 30; index++) {
      segmenter.add(frame(20000));
    }
    for (var index = 0; index < 10; index++) {
      segmenter.add(frame(0));
    }

    expect(segments, hasLength(1));
    final segment = segments.single;
    expect(segment.startMs, 160, reason: '预卷 2 帧，起点应提前到 160ms');
    expect(segment.endMs - segment.startMs, 840);
    expect(segment.pcm.length, 840 * 32);
  });

  test('不足最短长度时不会因短暂停顿收段', () {
    final segments = <VadSegment>[];
    final segmenter = VadSegmenter(
      onSegment: segments.add,
      silenceMs: 100,
      minSegmentMs: 1000,
      maxSegmentMs: 10000,
      prerollMs: 20,
    );

    for (var index = 0; index < 20; index++) {
      segmenter.add(frame(20000));
    }
    for (var index = 0; index < 20; index++) {
      segmenter.add(frame(0));
    }
    expect(segments, isEmpty, reason: '400ms 有声 + 400ms 静音还不够 1 秒');

    for (var index = 0; index < 40; index++) {
      segmenter.add(frame(20000));
    }
    for (var index = 0; index < 5; index++) {
      segmenter.add(frame(0));
    }
    expect(segments, hasLength(1));
  });

  test('flush 会收掉最后一段，过短则丢弃', () {
    final segments = <VadSegment>[];
    final segmenter = VadSegmenter(
      onSegment: segments.add,
      minSegmentMs: 2000,
      maxSegmentMs: 30000,
      prerollMs: 20,
    );

    for (var index = 0; index < 30; index++) {
      segmenter.add(frame(20000));
    }
    segmenter.flush(minMs: 200);
    expect(segments, hasLength(1));

    // 再来一段极短噪声：flush 时按 minMs 丢掉。
    segmenter.add(frame(20000));
    segmenter.flush(minMs: 200);
    expect(segments, hasLength(1));
  });

  test('一次点击/瞬态不会变成语音分段', () {
    final segments = <VadSegment>[];
    final segmenter = VadSegmenter(
      onSegment: segments.add,
      silenceMs: 200,
      minSegmentMs: 200,
      maxSegmentMs: 10000,
      prerollMs: 20,
      minSpeechMs: 180,
    );

    // 一帧瞬态（20ms）后接 2 秒静音：段长够 200ms，但没有持续说话。
    segmenter.add(frame(20000));
    for (var index = 0; index < 100; index++) {
      segmenter.add(frame(0));
    }
    expect(segments, isEmpty, reason: '瞬态不应触发转写请求');
  });

  test('超过最长段长会强制切开', () {
    final segments = <VadSegment>[];
    final segmenter = VadSegmenter(
      onSegment: segments.add,
      silenceMs: 600,
      minSegmentMs: 200,
      maxSegmentMs: 1000,
      prerollMs: 20,
    );

    for (var index = 0; index < 80; index++) {
      segmenter.add(frame(20000));
    }

    expect(segments.length, greaterThanOrEqualTo(1));
    expect(segments.first.endMs - segments.first.startMs, 1000);
  });
}
