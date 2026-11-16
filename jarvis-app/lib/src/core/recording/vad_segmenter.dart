import 'dart:math' as math;
import 'dart:typed_data';

import 'wav.dart';

/// 一段闭合的音频。
class VadSegment {
  const VadSegment({
    required this.pcm,
    required this.startMs,
    required this.endMs,
  });

  /// 裸 PCM16（16kHz 单声道），不含 WAV 头。
  final Uint8List pcm;
  final int startMs;
  final int endMs;
}

/// 按静音断句。
///
/// 为什么不是固定 10 秒硬切：硬切会落在字中间，转写端只能靠文本去重来补救，
/// 而"切在静音里"从根上避免断字。代价是段长不固定，服务端按任意长度接收。
///
/// 参数都是时间而非帧数，调用方不用关心 20ms 一帧的实现细节：
/// - 连续静音 600ms 收段（比常见的 500ms 稍长，中文停顿多）；
/// - 单段 2–30 秒，太短不出稿、太长转写等待明显；
/// - 段首带 250ms 预卷，避免吞掉第一个字的起音。
class VadSegmenter {
  VadSegmenter({
    required this.onSegment,
    this.frameMs = 20,
    this.silenceMs = 600,
    this.minSegmentMs = 2000,
    this.maxSegmentMs = 30000,
    this.prerollMs = 250,
    this.minSpeechMs = 120,
    this.noiseFloor = 0.0035,
  });

  final void Function(VadSegment segment) onSegment;
  final int frameMs;
  final int silenceMs;
  final int minSegmentMs;
  final int maxSegmentMs;
  final int prerollMs;

  /// 一段里至少要有这么久的"高于噪声底"的帧才算说话。
  ///
  /// 2 秒的段长门槛挡不住一次鼠标点击/碰麦：瞬态只触发一两帧，
  /// 后面全是静音，段长照样能凑够 2 秒。把这种段发给上游只会得到
  /// `ASR_RESPONSE_HAVE_NO_WORDS`，白白产生一条失败记录。
  final int minSpeechMs;

  double noiseFloor;

  final BytesBuilder _carry = BytesBuilder();
  final List<Uint8List> _preroll = <Uint8List>[];
  final List<Uint8List> _active = <Uint8List>[];

  int _frameIndex = 0;
  int _activeStartFrame = 0;
  int _silenceRunMs = 0;
  int _speechMs = 0;
  bool _speaking = false;

  /// 当前段的实际时长（毫秒）。
  int get _activeMs => _active.length * frameMs;

  int get _frameBytes =>
      kRecordingSampleRate * frameMs ~/ 1000 * kRecordingBytesPerSample;

  int get _prerollFrames => math.max(1, prerollMs ~/ frameMs);

  bool get isCapturing => _active.isNotEmpty;

  /// 持续喂入采集流。分片大小任意，内部按 20ms 对齐。
  void add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    _carry.add(chunk);
    final buffered = _carry.takeBytes();
    final frameBytes = _frameBytes;

    var offset = 0;
    while (buffered.length - offset >= frameBytes) {
      final frame = Uint8List.sublistView(
        buffered,
        offset,
        offset + frameBytes,
      );
      offset += frameBytes;
      _processFrame(Uint8List.fromList(frame));
    }

    if (offset < buffered.length) {
      _carry.add(Uint8List.sublistView(buffered, offset));
    }
  }

  void _processFrame(Uint8List frame) {
    final level = rmsLevel(frame);
    final threshold = math.max(0.006, noiseFloor * 3.0);
    final speech = level >= threshold;

    if (!_speaking) {
      if (!speech) {
        // 只在安静时更新噪声底：说话声不该被当成环境噪声。
        noiseFloor = noiseFloor * 0.98 + level * 0.02;
      }
    }

    if (_active.isEmpty) {
      if (speech) {
        _speaking = true;
        // 先带上"说话之前"的预卷，再接当前帧。顺序反了会把预卷挤掉一帧，
        // 第一个字的起音就听不见了。
        _active.addAll(_preroll);
        _active.add(frame);
        _activeStartFrame = math.max(0, _frameIndex - _preroll.length);
        _preroll.clear();
        _silenceRunMs = 0;
        _speechMs = frameMs;
      } else {
        _preroll.add(frame);
        if (_preroll.length > _prerollFrames) {
          _preroll.removeAt(0);
        }
      }
      _frameIndex++;
      return;
    }

    _active.add(frame);
    if (speech) {
      _speaking = true;
      _silenceRunMs = 0;
      _speechMs += frameMs;
    } else {
      _silenceRunMs += frameMs;
    }

    final reachedSilence = _silenceRunMs >= silenceMs;
    final reachedMax = _activeMs >= maxSegmentMs;
    final longEnough = _activeMs >= minSegmentMs;

    if (reachedMax || (reachedSilence && longEnough)) {
      _emit();
    }
    _frameIndex++;
  }

  /// 结束当前段（停止录音、暂停、切后台时调用）。
  ///
  /// [minMs] 用来过滤掉误触产生的极短片段；默认只丢掉不足 200ms 的噪声。
  void flush({int minMs = 200}) {
    if (_active.isNotEmpty && _activeMs >= minMs) {
      _emit();
    } else {
      _active.clear();
      _speaking = false;
      _silenceRunMs = 0;
      _speechMs = 0;
    }
    _preroll.clear();
  }

  void reset() {
    _carry.clear();
    _preroll.clear();
    _active.clear();
    _frameIndex = 0;
    _activeStartFrame = 0;
    _silenceRunMs = 0;
    _speechMs = 0;
    _speaking = false;
  }

  void _emit() {
    // 只有瞬态、没有持续说话的段直接丢弃，不产生空转写与失败记录。
    if (_speechMs < minSpeechMs) {
      _active.clear();
      _preroll.clear();
      _speaking = false;
      _silenceRunMs = 0;
      _speechMs = 0;
      return;
    }

    final pcm = Uint8List(
      _active.fold<int>(0, (total, frame) => total + frame.length),
    );
    var offset = 0;
    for (final frame in _active) {
      pcm.setRange(offset, offset + frame.length, frame);
      offset += frame.length;
    }

    final startMs = _activeStartFrame * frameMs;
    final segment = VadSegment(
      pcm: pcm,
      startMs: startMs,
      endMs: startMs + pcmDurationMs(pcm.length),
    );

    _active.clear();
    _preroll.clear();
    _speaking = false;
    _silenceRunMs = 0;
    _speechMs = 0;
    onSegment(segment);
  }
}
