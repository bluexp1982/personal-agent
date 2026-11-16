import 'dart:typed_data';

import 'package:jarvis_app/src/core/recording/wav.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pcm(int durationMs) => Uint8List(durationMs * 32);

void main() {
  test('buildWav 写出标准 44 字节头', () {
    final wav = buildWav(pcm(1000));
    expect(wav.length, 44 + 32000);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    final header = ByteData.sublistView(wav);
    expect(header.getUint16(20, Endian.little), 1);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint32(40, Endian.little), 32000);
  });

  test('pcmDurationMs 与采样率一致', () {
    expect(pcmDurationMs(32000), 1000);
    expect(pcmDurationMs(0), 0);
  });

  test('concatWavPcm 按顺序拼接 data 段', () {
    final first = buildWav(Uint8List.fromList(List<int>.filled(320, 1)));
    final second = buildWav(Uint8List.fromList(List<int>.filled(640, 2)));
    final joined = concatWavPcm(<Uint8List>[first, second]);
    expect(joined.length, 44 + 960);
    expect(joined[44], 1);
    expect(joined[44 + 320], 2);
    expect(pcmDurationMs(joined.length - 44), 30);
  });

  test('rmsLevel 对静音与满幅给出可区分的结果', () {
    expect(rmsLevel(Uint8List(640)), 0);
    final loud = ByteData(640);
    for (var index = 0; index < 320; index++) {
      loud.setInt16(index * 2, 32767, Endian.little);
    }
    expect(rmsLevel(loud.buffer.asUint8List()), greaterThan(0.9));
    expect(visualLevel(0), 0);
    expect(visualLevel(1), 1);
  });

  test('peakLevel 对静音与满幅给出端点值', () {
    expect(peakLevel(Uint8List(640)), 0);
    final loud = ByteData(640);
    for (var index = 0; index < 320; index++) {
      loud.setInt16(index * 2, -32768, Endian.little);
    }
    expect(peakLevel(loud.buffer.asUint8List()), 1);
  });

  test('peakLevel 抓住单点冲击，rmsLevel 会被均摊', () {
    final impulse = ByteData(32000);
    impulse.setInt16(16000, 32767, Endian.little);
    final pcm = impulse.buffer.asUint8List();
    expect(peakLevel(pcm), greaterThan(0.99));
    expect(rmsLevel(pcm), lessThan(0.2));
  });

  test('peakLevel 与 rmsLevel 在奇数字节下都不抛异常', () {
    final odd = Uint8List.fromList(<int>[0xFF, 0x7F, 0x01]);
    expect(peakLevel(odd), greaterThan(0.99));
    expect(rmsLevel(odd), greaterThan(0));
    expect(peakLevel(Uint8List(1)), 0);
  });
}
