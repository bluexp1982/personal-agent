import 'package:jarvis_app/src/core/design/app_theme.dart';
import 'package:jarvis_app/src/core/recording/recording_models.dart';
import 'package:jarvis_app/src/features/recordings/recording_summary_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

RecordingSummary _summary({
  SummaryStatus status = SummaryStatus.none,
  String text = '',
  SummaryStyle? style,
  SummaryStyle stylePreference = SummaryStyle.brief,
  String? error,
  SummaryAudioStatus audioStatus = SummaryAudioStatus.none,
}) => RecordingSummary(
  status: status,
  text: text,
  style: style,
  stylePreference: stylePreference,
  error: error,
  audioStatus: audioStatus,
);

Widget _harness(
  RecordingSummary summary, {
  RecordingStatus recordingStatus = RecordingStatus.ready,
  Future<void> Function(SummaryStyle style)? onStyleSelected,
  Future<void> Function(SummaryStyle style)? onRegenerate,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: RecordingSummaryTab(
          serverId: 'rec_1',
          recordingStatus: recordingStatus,
          summary: summary,
          summaryAvailable: true,
          ttsAvailable: false,
          playerKey: GlobalKey<RecordingSummaryPlayerState>(),
          onWillPlayTts: () {},
          onEnsureAudio: () async {},
          onStyleSelected: onStyleSelected ?? (style) async {},
          onRegenerate: onRegenerate ?? (style) async {},
        ),
      ),
    ),
  );
}

void main() {
  test('总结 JSON 解析状态、文本与语音字段', () {
    final detail = ServerRecordingDetail.fromJson(<String, dynamic>{
      'recording': <String, dynamic>{
        'id': 'rec_1',
        'client_recording_id': 'local-1',
        'title': '周会',
        'mode': 'realtime',
        'status': 'ready',
        'duration_ms': 1000,
        'bytes': 32044,
        'segment_count': 1,
        'ready_count': 1,
        'preview': '测试',
        'created_at': 1,
        'updated_at': 2,
      },
      'segments': <dynamic>[],
      'summary': <String, dynamic>{
        'status': 'ready',
        'text': '## 概要\n测试总结',
        'audio_status': 'ready',
        'audio_bytes': 1024,
        'audio_format': 'mp3',
        'audio_truncated': true,
      },
    });

    expect(detail.summary.status, SummaryStatus.ready);
    expect(detail.summary.isReady, isTrue);
    expect(detail.summary.audioStatus, SummaryAudioStatus.ready);
    expect(detail.summary.audioBytes, 1024);
    expect(detail.summary.audioTruncated, isTrue);
  });

  test('旧详情没有 summary 时按 none 处理', () {
    final detail = ServerRecordingDetail.fromJson(<String, dynamic>{
      'recording': <String, dynamic>{},
      'segments': <dynamic>[],
    });
    expect(detail.summary.status, SummaryStatus.none);
    expect(detail.summary.audioStatus, SummaryAudioStatus.none);
  });

  testWidgets('等待转写时显示原因而不是生成按钮', (tester) async {
    await tester.pumpWidget(
      _harness(_summary(), recordingStatus: RecordingStatus.transcribing),
    );
    expect(find.text('等待转写完成'), findsOneWidget);
    expect(find.text('全部分段转写完成后会自动生成总结。'), findsOneWidget);
    expect(find.text('生成总结'), findsNothing);
  });

  testWidgets('失败时显示原因与重新生成入口', (tester) async {
    await tester.pumpWidget(
      _harness(_summary(status: SummaryStatus.failed, error: '模型暂时不可用')),
    );
    expect(find.text('总结生成失败'), findsOneWidget);
    expect(find.text('模型暂时不可用'), findsOneWidget);
    expect(find.textContaining('重新生成'), findsOneWidget);
  });

  testWidgets('已生成时渲染 Markdown 与重新生成按钮', (tester) async {
    await tester.pumpWidget(
      _harness(_summary(status: SummaryStatus.ready, text: '## 概要\n今天对齐目标。')),
    );
    expect(find.text('总结'), findsOneWidget);
    expect(find.textContaining('今天对齐目标'), findsOneWidget);
    expect(find.textContaining('重新生成'), findsOneWidget);
  });

  testWidgets('选择形式只保存选择，不触发重新生成', (tester) async {
    SummaryStyle? picked;
    var regenerated = 0;
    await tester.pumpWidget(
      _harness(
        _summary(
          status: SummaryStatus.ready,
          text: '## 概要\n旧内容。',
          style: SummaryStyle.minutes,
          stylePreference: SummaryStyle.minutes,
        ),
        onStyleSelected: (style) async => picked = style,
        onRegenerate: (style) async => regenerated++,
      ),
    );

    await tester.tap(find.text('会议纪要式').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('简短摘要'));
    await tester.pumpAndSettle();

    expect(picked, SummaryStyle.brief);
    expect(regenerated, 0);
  });

  test('峰值解析：版本号、越界值夹住', () {
    final peaks = SummaryAudioPeaks.fromJson(<String, dynamic>{
      'version': 1700000000000,
      'buckets': 3,
      'peaks': <dynamic>[0, 300, -2],
    });
    expect(peaks.version, 1700000000000);
    expect(peaks.isUsable, isTrue);
    expect(peaks.peaks.toList(), <int>[0, 255, 0]);
  });

  test('峰值解析：缺字段或空数组时降级为空', () {
    expect(SummaryAudioPeaks.fromJson(<String, dynamic>{}).isUsable, isFalse);
    expect(
      SummaryAudioPeaks.fromJson(<String, dynamic>{
        'version': 1,
        'peaks': <dynamic>[],
      }).isUsable,
      isFalse,
    );
    expect(
      SummaryAudioPeaks.fromJson(<String, dynamic>{'peaks': 'oops'}).isUsable,
      isFalse,
    );
  });

  testWidgets('切换形式后提示需要重新生成才生效', (tester) async {
    await tester.pumpWidget(
      _harness(
        _summary(
          status: SummaryStatus.ready,
          text: '## 概要\n这是旧的会议纪要。',
          style: SummaryStyle.minutes,
          stylePreference: SummaryStyle.brief,
        ),
      ),
    );
    expect(find.text('会议纪要式'), findsOneWidget);
    expect(find.text('简短摘要'), findsOneWidget);
    expect(find.textContaining('点击重新生成后生效'), findsOneWidget);
    expect(find.textContaining('按简短摘要重新生成'), findsOneWidget);
  });
}
