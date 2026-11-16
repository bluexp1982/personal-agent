import 'package:jarvis_app/src/core/recording/recording_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// 取自一条真实录音：音频只保留说话段，总长 27.2s；
/// 时间轴从第一段 2.26s 到 71.68s，中间有大段静音。
const List<RecordingTimelineSegment> _segments = <RecordingTimelineSegment>[
  RecordingTimelineSegment(startMs: 2260, endMs: 4260, bytes: 64044),
  RecordingTimelineSegment(startMs: 5960, endMs: 10560, bytes: 147244),
  RecordingTimelineSegment(startMs: 12180, endMs: 18520, bytes: 202924),
  RecordingTimelineSegment(startMs: 18640, endMs: 20640, bytes: 64044),
  RecordingTimelineSegment(startMs: 43960, endMs: 46180, bytes: 71084),
  RecordingTimelineSegment(startMs: 49820, endMs: 51820, bytes: 64044),
  RecordingTimelineSegment(startMs: 55880, endMs: 60220, bytes: 138924),
  RecordingTimelineSegment(startMs: 63260, endMs: 65260, bytes: 64044),
  RecordingTimelineSegment(startMs: 69980, endMs: 71680, bytes: 54444),
];

void main() {
  test('音频总长按分段字节数累加，而不是录制时间轴长度', () {
    final timeline = RecordingTimeline(_segments);
    expect(timeline.audioDurationMs, 27200);
    expect(timeline.spans.length, 9);
  });

  test('播放到音频末尾映射到时间轴末尾', () {
    final timeline = RecordingTimeline(_segments);
    expect(timeline.toTimeline(27200), 71680);
  });

  test('段内播放位置按时间轴平移', () {
    final timeline = RecordingTimeline(_segments);
    expect(timeline.toTimeline(0), 0);
    // 第一段音频 1s 处 = 时间轴 3.26s。
    expect(timeline.toTimeline(1000), 3260);
  });

  test('段落之间的静音在 seek 时吸附到下一段开头', () {
    final timeline = RecordingTimeline(_segments);
    // 30s 落在第 4 段（43.96s）之前的静音里，吸附到第 4 段音频开头。
    expect(timeline.toAudio(30000), 14940);
    expect(timeline.toAudio(5000), 2000);
  });

  test('seek 到末尾与开头都能落在有效音频偏移上', () {
    final timeline = RecordingTimeline(_segments);
    expect(timeline.toAudio(0), 0);
    expect(timeline.toAudio(71680), 27200);
    expect(timeline.toAudio(999999), 27200);
  });

  test('没有字节数时退回分段时长，空列表不崩', () {
    final timeline = RecordingTimeline(const <RecordingTimelineSegment>[
      RecordingTimelineSegment(startMs: 1000, endMs: 4000, bytes: 0),
    ]);
    expect(timeline.audioDurationMs, 3000);
    expect(timeline.toTimeline(1500), 2500);
    expect(
      RecordingTimeline(const <RecordingTimelineSegment>[]).toTimeline(5),
      5,
    );
  });
}
