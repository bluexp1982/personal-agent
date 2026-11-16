import 'dart:typed_data';

import '../api_client.dart';
import 'recording_models.dart';

/// `/api/recordings/*` 的薄封装。
///
/// 只做「路径 + 解析」，不做重试与状态机：那些属于 uploader，
/// 混在一起会让"哪一层该负责重传"变得说不清。
class RecordingApi {
  RecordingApi(this._client);

  final ApiClient _client;

  Future<RecordingInfo> info() async {
    final json = await _client.getJson('/api/recordings/info');
    return RecordingInfo.fromJson(json);
  }

  Future<RecordingPage> list({
    String? query,
    RecordingStatus? status,
    String? cursor,
    int limit = 30,
  }) async {
    final params = <String, String>{'limit': '$limit'};
    if (query != null && query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    if (status != null) {
      params['status'] = status.name;
    }
    if (cursor != null) {
      params['cursor'] = cursor;
    }
    final json = await _client.getJson('/api/recordings', query: params);
    return RecordingPage.fromJson(json);
  }

  Future<ServerRecording> create({
    required String clientId,
    required String title,
    required RecordingMode mode,
  }) async {
    final json = await _client.postJson('/api/recordings', <String, dynamic>{
      'client_recording_id': clientId,
      'title': title,
      'mode': mode.wire,
    });
    return ServerRecording.fromJson(json);
  }

  Future<ServerRecordingDetail> detail(String id) async {
    final json = await _client.getJson('/api/recordings/$id');
    return ServerRecordingDetail.fromJson(json);
  }

  Future<ServerRecording> rename(String id, String title) async {
    final json = await _client.patchJson(
      '/api/recordings/$id',
      <String, dynamic>{'title': title},
    );
    return ServerRecording.fromJson(json);
  }

  Future<void> delete(String id) => _client.delete('/api/recordings/$id');

  Future<ServerSegment> uploadSegment({
    required String id,
    required int seq,
    required int startMs,
    required int endMs,
    required Uint8List bytes,
  }) async {
    final json = await _client.postBytes(
      '/api/recordings/$id/segments/$seq',
      bytes,
      contentType: 'audio/wav',
      query: <String, String>{'start_ms': '$startMs', 'end_ms': '$endMs'},
    );
    return ServerSegment.fromJson(json);
  }

  Future<ServerRecordingDetail> complete(String id, {int? durationMs}) async {
    final json = await _client.postJson(
      '/api/recordings/$id/complete',
      <String, dynamic>{
        if (durationMs != null && durationMs > 0) 'duration_ms': durationMs,
      },
    );
    return ServerRecordingDetail.fromJson(json);
  }

  Future<ServerRecordingDetail> retry(String id) async {
    final json = await _client.postJson(
      '/api/recordings/$id/retry',
      <String, dynamic>{},
    );
    return ServerRecordingDetail.fromJson(json);
  }

  Future<Uint8List> audio(String id) async {
    final result = await _client.getBytes('/api/recordings/$id/audio');
    return Uint8List.fromList(result.bytes);
  }

  Future<ServerRecordingDetail> updateSummaryStyle(
    String id,
    SummaryStyle style,
  ) async {
    final json = await _client.patchJson(
      '/api/recordings/$id/summary',
      <String, dynamic>{'style': style.wire},
    );
    return ServerRecordingDetail.fromJson(json);
  }

  Future<ServerRecordingDetail> regenerateSummary(
    String id, {
    SummaryStyle? style,
  }) async {
    final json = await _client.postJson(
      '/api/recordings/$id/summary',
      <String, dynamic>{if (style != null) 'style': style.wire},
    );
    return ServerRecordingDetail.fromJson(json);
  }

  Future<ServerRecordingDetail> ensureSummaryAudio(String id) async {
    final json = await _client.postJson(
      '/api/recordings/$id/summary/audio',
      <String, dynamic>{},
    );
    return ServerRecordingDetail.fromJson(json);
  }

  Future<Uint8List> summaryAudio(String id) async {
    final result = await _client.getBytes('/api/recordings/$id/summary/audio');
    return Uint8List.fromList(result.bytes);
  }

  /// 总结语音的波形峰值。失败由调用方静默降级，不在这里兜底成空数组：
  /// "接口没通"和"确实没有波形"要能区分开。
  Future<SummaryAudioPeaks> summaryAudioPeaks(String id) async {
    final json = await _client.getJson(
      '/api/recordings/$id/summary/audio/peaks',
    );
    return SummaryAudioPeaks.fromJson(json);
  }
}
