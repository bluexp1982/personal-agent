import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jarvis_app/src/core/api_client.dart';
import 'package:jarvis_app/src/core/recording/recording_api.dart';
import 'package:jarvis_app/src/core/recording/recording_models.dart';
import 'package:jarvis_app/src/core/recording/recording_store.dart';
import 'package:jarvis_app/src/core/recording/recording_uploader.dart';
import 'package:jarvis_app/src/core/recording/vad_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> recordingJson({
  String id = 'rec_server',
  String status = 'ready',
  int durationMs = 1000,
}) => <String, dynamic>{
  'id': id,
  'client_recording_id': 'local-1',
  'title': '测试录音',
  'mode': 'batch',
  'status': status,
  'duration_ms': durationMs,
  'bytes': 32044,
  'segment_count': 1,
  'ready_count': status == 'ready' ? 1 : 0,
  'preview': '转写文本 0',
  'created_at': 1,
  'updated_at': 2,
};

Map<String, dynamic> segmentJson(int seq) => <String, dynamic>{
  'seq': seq,
  'start_ms': seq * 1000,
  'end_ms': (seq + 1) * 1000,
  'bytes': 32044,
  'text': '转写文本 $seq',
  'state': 'ready',
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

VadSegment _segment(int startMs) => VadSegment(
  pcm: Uint8List(1000 * 32),
  startMs: startMs,
  endMs: startMs + 1000,
);

void main() {
  late Directory root;
  late RecordingStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('recording-uploader-test');
    store = RecordingStore(root: root);
    await store.init();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  RecordingApi mockApi({required List<String> calls}) {
    final client = MockClient((request) async {
      final path = request.url.path;
      calls.add('${request.method} $path');

      if (request.method == 'POST' && path == '/api/recordings') {
        return _json(recordingJson(status: 'recording'), 201);
      }
      if (request.method == 'POST' && path.contains('/segments/')) {
        final seq = int.parse(path.split('/').last);
        return _json(segmentJson(seq), 201);
      }
      if (request.method == 'POST' && path.endsWith('/complete')) {
        return _json(<String, dynamic>{
          'recording': recordingJson(),
          'segments': <Map<String, dynamic>>[segmentJson(0)],
        });
      }
      if (request.method == 'GET') {
        return _json(<String, dynamic>{
          'recording': recordingJson(),
          'segments': <Map<String, dynamic>>[segmentJson(0)],
        });
      }
      return _json(<String, dynamic>{'code': 'not_found'}, 404);
    });

    return RecordingApi(
      ApiClient(
        baseUrl: 'http://127.0.0.1:9',
        token: 'test-token',
        httpClient: client,
      ),
    );
  }

  test('批量录音：上传分段后 complete，并写入转写文本', () async {
    final recording = store.newRecording(mode: RecordingMode.batch);
    await store.save(recording);
    await store.appendSegment(recording, _segment(0));
    recording.completed = true;
    recording.durationMs = 1000;
    await store.save(recording);

    final calls = <String>[];
    final uploader = RecordingUploader(
      api: mockApi(calls: calls),
      store: store,
      pollInterval: Duration.zero,
    );

    await uploader.sync(recording);

    expect(recording.serverId, 'rec_server');
    expect(recording.segments.single.uploaded, isTrue);
    expect(recording.segments.single.text, '转写文本 0');
    expect(recording.segments.single.state, SegmentState.ready);
    expect(
      calls.any((call) => call.endsWith('/complete')),
      isTrue,
      reason: '结束的录音必须触发整体转写',
    );
    expect(
      calls.where((call) => call.contains('/segments/')).length,
      1,
      reason: '同一段不该重复上传',
    );
  });

  test('实时录音：未结束时只上传分段，不调用 complete', () async {
    final recording = store.newRecording(mode: RecordingMode.realtime);
    await store.save(recording);
    await store.appendSegment(recording, _segment(0));

    final calls = <String>[];
    final uploader = RecordingUploader(
      api: mockApi(calls: calls),
      store: store,
      pollInterval: Duration.zero,
    );

    await uploader.sync(recording);

    expect(recording.serverId, isNotNull);
    expect(recording.segments.single.uploaded, isTrue);
    expect(calls.any((call) => call.endsWith('/complete')), isFalse);
  });
}
