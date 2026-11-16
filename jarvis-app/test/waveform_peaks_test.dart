import 'dart:io';
import 'dart:typed_data';

import 'package:jarvis_app/src/core/recording/wav.dart';
import 'package:jarvis_app/src/core/recording/waveform_peaks.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pcmOfSamples(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var index = 0; index < samples.length; index++) {
    data.setInt16(index * 2, samples[index], Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List loudPcm(int samples, {int value = 32767}) =>
    pcmOfSamples(List<int>.filled(samples, value));

void main() {
  group('peaksFromPcm', () {
    test('桶数与 kWaveformBuckets 一致', () {
      final peaks = peaksFromPcm(loudPcm(16000));
      expect(peaks.length, kWaveformBuckets);
    });

    test('静音全 0，满幅近 255', () {
      expect(peaksFromPcm(Uint8List(32000)).every((v) => v == 0), isTrue);
      final peaks = peaksFromPcm(loudPcm(960));
      expect(peaks.every((v) => v >= 250), isTrue);
    });

    test('负半轴按绝对值取峰值', () {
      final peaks = peaksFromPcm(pcmOfSamples(<int>[-32768, -32768]));
      expect(peaks.first, 255);
    });

    test('奇数字节只丢尾字节，不抛异常', () {
      final pcm = Uint8List.fromList(<int>[0xFF, 0x7F, 0x00]);
      final peaks = peaksFromPcm(pcm);
      expect(peaks.length, kWaveformBuckets);
      expect(peaks[0], 255);
    });

    test('峰值落在对应时间位置的桶里', () {
      const samples = 4800;
      final samplesList = List<int>.filled(samples, 0);
      samplesList[samples - 1] = 32767;
      final peaks = peaksFromPcm(pcmOfSamples(samplesList));
      expect(peaks.last, greaterThan(200));
      expect(peaks.first, 0);
    });

    test('桶数为 0 时返回空数组', () {
      expect(peaksFromPcm(loudPcm(32), buckets: 0), isEmpty);
    });
  });

  group('peaksFromWavFile', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('waveform_peaks'));
    tearDown(() => dir.deleteSync(recursive: true));

    File writeWav(String name, Uint8List bytes) {
      final file = File('${dir.path}/$name');
      file.writeAsBytesSync(bytes);
      return file;
    }

    test('读取标准 44 字节头 WAV', () async {
      final file = writeWav('loud.wav', buildWav(loudPcm(16000)));
      final peaks = await peaksFromWavFile(file.path);
      expect(peaks, isNotNull);
      expect(peaks!.length, kWaveformBuckets);
      expect(peaks.every((v) => v >= 250), isTrue);
    });

    test('静音文件返回全 0 而不是 null', () async {
      final file = writeWav('silent.wav', buildWav(Uint8List(32000)));
      final peaks = await peaksFromWavFile(file.path);
      expect(peaks, isNotNull);
      expect(peaks!.every((v) => v == 0), isTrue);
    });

    test('非 RIFF 头返回 null', () async {
      final file = writeWav(
        'bad.wav',
        Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      );
      expect(await peaksFromWavFile(file.path), isNull);
    });

    test('WAVE 头但格式不是 PCM16 时返回 null', () async {
      final bytes = buildWav(loudPcm(320));
      final broken = Uint8List.fromList(bytes);
      ByteData.sublistView(broken).setUint16(34, 8, Endian.little);
      final file = writeWav('pcm8.wav', broken);
      expect(await peaksFromWavFile(file.path), isNull);
    });

    test('文件不存在返回 null', () async {
      expect(await peaksFromWavFile('${dir.path}/missing.wav'), isNull);
    });

    test('头声明长度超过真实文件时按实际长度截断', () async {
      final bytes = buildWav(loudPcm(1600));
      final truncated = Uint8List.sublistView(bytes, 0, 44 + 1920);
      final file = writeWav('truncated.wav', truncated);
      final peaks = await peaksFromWavFile(file.path);
      expect(peaks, isNotNull);
      expect(peaks!.every((v) => v >= 250), isTrue);
    });

    test('奇数字节 data 段不抛异常', () async {
      final bytes = buildWav(pcmOfSamples(<int>[32767, 0, 16384]));
      final odd = Uint8List(bytes.length + 1)..setRange(0, bytes.length, bytes);
      final file = writeWav('odd.wav', odd);
      final peaks = await peaksFromWavFile(file.path);
      expect(peaks, isNotNull);
      expect(peaks!.first, 255);
    });
  });

  group('normalizePeaks', () {
    test('轻声录音按 95 分位放大后可见', () {
      final peaks = Uint8List(kWaveformBuckets)..fillRange(0, 480, 20);
      final normalized = normalizePeaks(peaks);
      expect(normalized.first, greaterThan(60));
    });

    test('增益上限 4 倍', () {
      final peaks = Uint8List(kWaveformBuckets)..fillRange(0, 480, 5);
      final normalized = normalizePeaks(peaks);
      expect(normalized.first, 20);
    });

    test('全静音保持全 0', () {
      final normalized = normalizePeaks(Uint8List(kWaveformBuckets));
      expect(normalized.every((v) => v == 0), isTrue);
    });

    test('不改动入参', () {
      final peaks = Uint8List(kWaveformBuckets)..fillRange(0, 480, 20);
      normalizePeaks(peaks);
      expect(peaks.every((v) => v == 20), isTrue);
    });
  });

  group('levelFromPeak', () {
    test('端点与越界值都被夹住', () {
      expect(levelFromPeak(0), 0);
      expect(levelFromPeak(255), 1);
      expect(levelFromPeak(999), 1);
      expect(levelFromPeak(-1), 0);
    });

    test('单调递增', () {
      var previous = -1.0;
      for (var peak = 0; peak <= 255; peak += 15) {
        final level = levelFromPeak(peak);
        expect(level, greaterThanOrEqualTo(previous));
        previous = level;
      }
    });
  });
}
