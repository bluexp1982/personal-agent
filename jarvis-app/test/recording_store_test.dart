import 'dart:io';
import 'dart:typed_data';

import 'package:jarvis_app/src/core/recording/recording_models.dart';
import 'package:jarvis_app/src/core/recording/recording_store.dart';
import 'package:jarvis_app/src/core/recording/vad_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';

VadSegment segment({required int startMs, required int durationMs}) {
  final pcm = Uint8List(durationMs * 32);
  for (var index = 0; index < pcm.length; index++) {
    pcm[index] = index % 251;
  }
  return VadSegment(pcm: pcm, startMs: startMs, endMs: startMs + durationMs);
}

void main() {
  late Directory root;
  late RecordingStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('recording-store-test');
    store = RecordingStore(root: root);
    await store.init();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('分段落盘、扫描恢复与拼接播放文件', () async {
    final recording = store.newRecording(mode: RecordingMode.realtime);
    await store.save(recording);

    final first = await store.appendSegment(
      recording,
      segment(startMs: 0, durationMs: 1000),
    );
    final second = await store.appendSegment(
      recording,
      segment(startMs: 1000, durationMs: 500),
    );

    expect(recording.segments, hasLength(2));
    expect(recording.durationMs, 1500);
    expect(recording.bytes, first.bytes + second.bytes);

    final scanned = await store.scan();
    expect(scanned, hasLength(1));
    expect(scanned.single.clientId, recording.clientId);
    expect(scanned.single.segments, hasLength(2));
    expect(scanned.single.durationMs, 1500);

    final playback = await store.ensurePlaybackFile(scanned.single);
    expect(await playback.length(), 44 + 1500 * 32);
  });

  test('删除会清掉整个录音目录', () async {
    final recording = store.newRecording(mode: RecordingMode.batch);
    await store.save(recording);
    await store.appendSegment(recording, segment(startMs: 0, durationMs: 100));

    final dir = store.recordingDir(recording);
    expect(await dir.exists(), isTrue);
    await store.delete(recording);
    expect(await dir.exists(), isFalse);
    expect(await store.scan(), isEmpty);
  });

  test('meta 损坏时跳过该条而不影响其它录音', () async {
    final good = store.newRecording(mode: RecordingMode.realtime);
    await store.save(good);

    final broken = Directory('${root.path}${Platform.pathSeparator}rec_broken');
    await broken.create(recursive: true);
    await File('${broken.path}${Platform.pathSeparator}meta.json')
        .writeAsString('{not-json');

    final scanned = await store.scan();
    expect(scanned.map((item) => item.clientId), <String>[good.clientId]);
  });

  test('本地账本 JSON 往返保留上传状态', () {
    final recording = LocalRecording(
      clientId: 'rec_1',
      title: '周会',
      mode: RecordingMode.batch,
      startedAt: 100,
      serverId: 'rec_server',
      durationMs: 2000,
      completed: true,
      segments: <LocalSegment>[
        LocalSegment(
          seq: 0,
          startMs: 0,
          endMs: 2000,
          bytes: 64044,
          uploaded: true,
          text: '今天先对齐目标',
          state: SegmentState.ready,
        ),
      ],
    );

    final restored = LocalRecording.fromJson(recording.toJson());
    expect(restored.serverId, 'rec_server');
    expect(restored.completed, isTrue);
    expect(restored.segments.single.uploaded, isTrue);
    expect(restored.segments.single.text, '今天先对齐目标');
    expect(restored.transcript, '今天先对齐目标');
  });
}
