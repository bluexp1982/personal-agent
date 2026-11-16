import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'wav.dart';

/// 峰值桶数：客户端与服务端唯一的约定。
///
/// 固定 480 桶（与服务端 `PEAK_BUCKETS` 一致），每桶一个 `0..255` 的线性
/// 幅度值。改这个数要两端一起改，否则回放波形密度会对不上。
const int kWaveformBuckets = 480;

/// 扫描大文件时参与计算的最大样本数。
///
/// 一小时录音约 5760 万样本，逐个读要几百毫秒以上；按这个上限动态放大
/// 步长后任何长度的文件都在 1 秒量级，而波形本身只有 480 个桶，多采没有
/// 意义。
const int _kMaxScannedSamples = 4000000;

/// 单次读盘的分块大小。
const int _kChunkBytes = 256 * 1024;

/// 从裸 PCM（16bit 单声道小端）统计出 [buckets] 个 0..255 峰值。
///
/// 纯内存版本，主要用于单测与将来"边录边算峰值"的场景。
Uint8List peaksFromPcm(Uint8List pcm, {int buckets = kWaveformBuckets}) {
  if (buckets <= 0) {
    return Uint8List(0);
  }
  final peaks = Uint8List(buckets);
  final samples = pcm.length ~/ 2;
  if (samples == 0) {
    return peaks;
  }
  final data = ByteData.sublistView(pcm, 0, samples * 2);
  for (var index = 0; index < samples; index++) {
    final amplitude = _amplitudeOf(data.getInt16(index * 2, Endian.little));
    final bucket = index * buckets ~/ samples;
    if (amplitude > peaks[bucket]) {
      peaks[bucket] = amplitude;
    }
  }
  return peaks;
}

/// 流式扫描一个标准 44 字节头 WAV 文件，返回 [buckets] 个 0..255 峰值。
///
/// 只处理本项目自己写出的头（[wavHeader]）；头不合法、格式不是 16bit PCM
/// 或文件读不了时返回 `null`，调用方退回旧进度条，绝不抛异常。
///
/// 用 `RandomAccessFile` 顺序分块读 + 动态步长采样，内存 O(1)：一小时
/// 录音（约 460MB）不会整段进内存。耗时的 IO 适合放进 `Isolate.run`。
Future<Uint8List?> peaksFromWavFile(
  String path, {
  int buckets = kWaveformBuckets,
}) async {
  if (buckets <= 0) {
    return null;
  }

  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final fileLength = await file.length();
    final header = await file.read(44);
    final layout = _parseWavLayout(header, fileLength);
    if (layout == null) {
      return null;
    }

    final peaks = Uint8List(buckets);
    final dataLength = layout.dataLength;
    final samples = dataLength ~/ 2;
    if (samples == 0) {
      return peaks;
    }

    final stride = math.max(1, (samples / _kMaxScannedSamples).ceil());
    final buffer = Uint8List(_kChunkBytes);
    var baseSample = 0;
    var nextSample = 0;
    var remaining = dataLength;

    while (remaining > 0) {
      final want = math.min(_kChunkBytes, remaining);
      final read = await file.readInto(buffer, 0, want);
      if (read <= 0) {
        break;
      }
      remaining -= read;

      final count = read ~/ 2;
      final chunkBase = baseSample;
      if (nextSample < chunkBase) {
        nextSample = chunkBase;
      }
      final data = ByteData.sublistView(buffer, 0, count * 2);
      for (var index = nextSample - chunkBase; index < count; index += stride) {
        final sample = chunkBase + index;
        final amplitude = _amplitudeOf(data.getInt16(index * 2, Endian.little));
        final bucket = (sample * buckets ~/ samples).clamp(0, buckets - 1);
        if (amplitude > peaks[bucket]) {
          peaks[bucket] = amplitude;
        }
        nextSample = sample + stride;
      }
      baseSample = chunkBase + count;
    }

    return peaks;
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}

/// 显示侧归一化：按 95 分位数把整条波形放大，最多放大 [maxGain] 倍。
///
/// 轻声录音的峰值可能只有 20 上下，直接画几乎是一条中线；先把 p95 拉到
/// 满幅再走 dB 曲线，轻声也看得出起伏。上限 4 倍是为了不让底噪被放大成
/// 噪声墙。
Uint8List normalizePeaks(
  Uint8List peaks, {
  double percentile = 0.95,
  double maxGain = 4,
}) {
  if (peaks.isEmpty) {
    return Uint8List(0);
  }
  final sorted = Uint8List.fromList(peaks)..sort();
  final index = ((sorted.length - 1) * percentile.clamp(0.0, 1.0)).round();
  final reference = sorted[index];
  if (reference == 0) {
    return Uint8List.fromList(peaks);
  }
  final gain = math.min(maxGain, 255 / reference);
  if (gain <= 1) {
    return Uint8List.fromList(peaks);
  }
  final out = Uint8List(peaks.length);
  for (var i = 0; i < peaks.length; i++) {
    out[i] = (peaks[i] * gain).round().clamp(0, 255);
  }
  return out;
}

/// `0..255` 的峰值 → `0..1` 的视觉高度。
///
/// 和录音时的电平共用 [visualLevel] 的 dB 曲线，保证"录的时候"和
/// "回放的时候"是同一种观感。
double levelFromPeak(int peak) => visualLevel(peak.clamp(0, 255) / 255);

int _amplitudeOf(int raw) {
  final value = raw < 0 ? -raw : raw;
  return math.min(255, (value * 255 / 32768).round());
}

/// 标准 44 字节头里我们需要的两个位置。
class _WavLayout {
  const _WavLayout({required this.dataLength});

  /// `data` 块长度（已按真实文件长度收敛）。
  final int dataLength;
}

_WavLayout? _parseWavLayout(Uint8List header, int fileLength) {
  if (header.length < 44 || fileLength <= 44) {
    // 空录音（只有头）按全静音处理更划算，但文件连头都不完整就是坏文件。
    return header.length < 44 ? null : const _WavLayout(dataLength: 0);
  }
  if (!_matchesAscii(header, 0, 'RIFF') ||
      !_matchesAscii(header, 8, 'WAVE') ||
      !_matchesAscii(header, 12, 'fmt ') ||
      !_matchesAscii(header, 36, 'data')) {
    return null;
  }

  final data = ByteData.sublistView(header);
  final format = data.getUint16(20, Endian.little);
  final channels = data.getUint16(22, Endian.little);
  final bitsPerSample = data.getUint16(34, Endian.little);
  if (format != 1 || channels == 0 || bitsPerSample != 16) {
    return null;
  }

  final declared = data.getUint32(40, Endian.little);
  final available = fileLength - 44;
  // 声明长度超过真实文件（录制被强杀、头先写后补）时按实际截断；
  // 声明为 0 但后面有数据（没收尾的头）时同样按实际长度读。
  final dataLength = declared == 0 ? available : math.min(declared, available);
  return _WavLayout(dataLength: dataLength ~/ 2 * 2);
}

bool _matchesAscii(Uint8List bytes, int offset, String value) {
  if (bytes.length < offset + value.length) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) {
      return false;
    }
  }
  return true;
}
