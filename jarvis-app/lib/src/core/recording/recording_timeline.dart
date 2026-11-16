/// 录制时间轴 ↔ 紧凑音频偏移的映射。
///
/// 录音只保留"有声音"的分段，段与段之间的静音不写进播放文件；
/// 转写时间戳却来自录制时间轴。播放器的 `position` 是紧凑音频内的偏移，
/// 直接拿它去和 `startMs/endMs` 比较，就会出现"音频播完了、进度条还停在
/// 一分钟中间"的现象。这个映射负责两边换算。
class RecordingTimeline {
  RecordingTimeline(Iterable<RecordingTimelineSegment> segments) {
    var audio = 0;
    for (final segment in segments) {
      final duration = segment.audioDurationMs;
      if (duration <= 0) {
        continue;
      }
      spans.add(
        RecordingTimelineSpan(
          startMs: segment.startMs,
          endMs: segment.endMs,
          audioStartMs: audio,
          audioEndMs: audio + duration,
        ),
      );
      audio += duration;
    }
  }

  final List<RecordingTimelineSpan> spans = <RecordingTimelineSpan>[];

  bool get isEmpty => spans.isEmpty;

  /// 紧凑音频的总时长（所有分段 PCM 之和）。
  int get audioDurationMs => spans.isEmpty ? 0 : spans.last.audioEndMs;

  /// 音频偏移 → 录制时间。播放位置落在一段内部时按比例平移。
  int toTimeline(int audioMs) {
    if (spans.isEmpty) {
      return audioMs;
    }
    if (audioMs <= 0) {
      return 0;
    }
    for (final span in spans) {
      if (audioMs < span.audioEndMs) {
        final offset = (audioMs - span.audioStartMs).clamp(
          0,
          span.endMs - span.startMs,
        );
        return span.startMs + offset;
      }
    }
    return spans.last.endMs;
  }

  /// 录制时间 → 音频偏移。落在静音间隙里时吸附到下一段开头。
  int toAudio(int timelineMs) {
    if (spans.isEmpty) {
      return timelineMs;
    }
    for (final span in spans) {
      if (timelineMs < span.startMs) {
        return span.audioStartMs;
      }
      if (timelineMs <= span.endMs) {
        final offset = (timelineMs - span.startMs).clamp(
          0,
          span.audioEndMs - span.audioStartMs,
        );
        return span.audioStartMs + offset;
      }
    }
    return spans.last.audioEndMs;
  }
}

class RecordingTimelineSpan {
  const RecordingTimelineSpan({
    required this.startMs,
    required this.endMs,
    required this.audioStartMs,
    required this.audioEndMs,
  });

  final int startMs;
  final int endMs;
  final int audioStartMs;
  final int audioEndMs;
}

/// 一段音频在录制时间轴上的位置，以及 WAV 字节数（含 44 字节头）。
class RecordingTimelineSegment {
  const RecordingTimelineSegment({
    required this.startMs,
    required this.endMs,
    required this.bytes,
  });

  final int startMs;
  final int endMs;
  final int bytes;

  int get audioDurationMs {
    final dataBytes = bytes - 44;
    if (dataBytes > 0) {
      return (dataBytes * 1000 / 32000).round();
    }
    return (endMs - startMs).clamp(0, 1 << 30);
  }
}
