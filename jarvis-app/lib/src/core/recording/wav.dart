import 'dart:math' as math;
import 'dart:typed_data';

/// 采样参数只有一套：16kHz / 单声道 / PCM16。
///
/// 服务端按同一组数值校验，任何一端改动都要同步改另一端，
/// 因此这两个常量只在这里定义一次。
const int kRecordingSampleRate = 16000;
const int kRecordingChannels = 1;
const int kRecordingBytesPerSample = 2;

/// 每秒 PCM 字节数。
const int kRecordingBytesPerSecond =
    kRecordingSampleRate * kRecordingChannels * kRecordingBytesPerSample;

/// PCM 数据对应的时长（毫秒）。
int pcmDurationMs(int pcmBytes) =>
    (pcmBytes * 1000 / kRecordingBytesPerSecond).round();

/// 只生成 44 字节 WAV 头。
///
/// 拼接长录音时先写头再流式追加 PCM，避免把整段音频读进内存。
Uint8List wavHeader(int dataLength) {
  final header = ByteData(44);
  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      header.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, kRecordingChannels, Endian.little);
  header.setUint32(24, kRecordingSampleRate, Endian.little);
  header.setUint32(28, kRecordingBytesPerSecond, Endian.little);
  header.setUint16(
    32,
    kRecordingChannels * kRecordingBytesPerSample,
    Endian.little,
  );
  header.setUint16(34, kRecordingBytesPerSample * 8, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, dataLength, Endian.little);
  return header.buffer.asUint8List();
}

/// 给裸 PCM 加 44 字节 WAV 头。播放、上传与归档都用它。
Uint8List buildWav(Uint8List pcm) {
  final out = Uint8List(44 + pcm.length);
  out.setRange(0, 44, wavHeader(pcm.length));
  out.setRange(44, out.length, pcm);
  return out;
}

/// 一组 PCM 片段的 RMS 电平，0..1。
///
/// 用于录音时的波形：只做展示，不做 VAD 判定（判定另有自适应噪声底）。
double rmsLevel(Uint8List pcm) {
  if (pcm.length < 2) {
    return 0;
  }
  final samples = pcm.length ~/ 2;
  final data = ByteData.sublistView(pcm, 0, samples * 2);
  var sum = 0.0;
  for (var index = 0; index < samples; index++) {
    final value = data.getInt16(index * 2, Endian.little) / 32768.0;
    sum += value * value;
  }
  return math.sqrt(sum / samples).clamp(0.0, 1.0);
}

/// 一组 PCM 片段的峰值电平，0..1。
///
/// 与 [rmsLevel] 同口径（都是 0..1 的幅度），只是取 chunk 内样本绝对值的
/// 最大值而不是均方根：录音波形要的是"一开口就看得见"的冲击感，RMS 会把
/// 起音抹平。VAD 判定不看这个值，另有自适应噪声底。
double peakLevel(Uint8List pcm) {
  if (pcm.length < 2) {
    return 0;
  }
  final samples = pcm.length ~/ 2;
  final data = ByteData.sublistView(pcm, 0, samples * 2);
  var peak = 0;
  for (var index = 0; index < samples; index++) {
    final value = data.getInt16(index * 2, Endian.little).abs();
    if (value > peak) {
      peak = value;
    }
  }
  return (peak / 32768.0).clamp(0.0, 1.0);
}

/// 把多段 WAV 的 PCM 部分拆出来再拼成一个 WAV。
///
/// 只处理 [buildWav] 产出的标准 44 字节头；导入外部音频不在本期范围。
Uint8List concatWavPcm(List<Uint8List> wavs) {
  var total = 0;
  final payloads = <Uint8List>[];
  for (final wav in wavs) {
    if (wav.length < 44) {
      continue;
    }
    final data = Uint8List.sublistView(wav, 44);
    payloads.add(data);
    total += data.length;
  }

  final pcm = Uint8List(total);
  var offset = 0;
  for (final payload in payloads) {
    pcm.setRange(offset, offset + payload.length, payload);
    offset += payload.length;
  }
  return buildWav(pcm);
}

/// 把 float 电平映射成 0..1 的视觉高度。
///
/// 直接线性映射会让轻声几乎看不见；这里用 dB 近似（-60dB 起）再夹到可视区间。
double visualLevel(double rms) {
  if (rms <= 0.0001) {
    return 0;
  }
  final db = 20 * (math.log(rms) / math.ln10);
  return ((db + 60) / 60).clamp(0.0, 1.0);
}
