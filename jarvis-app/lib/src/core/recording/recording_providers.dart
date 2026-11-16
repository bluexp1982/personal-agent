import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_error.dart';
import '../session.dart';
import 'audio_capture.dart';
import 'recording_api.dart';
import 'recording_foreground.dart';
import 'recording_models.dart';
import 'recording_store.dart';

/// 麦克风采集。测试里覆写成假的实现。
final Provider<AudioCapture> audioCaptureProvider = Provider<AudioCapture>((
  ref,
) {
  final capture = RecordAudioCapture();
  ref.onDispose(capture.dispose);
  return capture;
});

/// 录音期间的原生保活（Android 前台服务）。测试可覆写成 fake。
final Provider<RecordingForeground> recordingForegroundProvider =
    Provider<RecordingForeground>((ref) => const PlatformRecordingForeground());

/// 本地录音账本。首次读取时才解析应用目录，widget 测试可覆写。
final FutureProvider<RecordingStore> recordingStoreProvider =
    FutureProvider<RecordingStore>((ref) => RecordingStore.openDefault());

/// 录音接口。未登录/未就绪时为 null。
final Provider<RecordingApi?> recordingApiProvider = Provider<RecordingApi?>((
  ref,
) {
  final client = ref.watch(apiClientProvider);
  if (client == null) {
    return null;
  }
  return RecordingApi(client);
});

/// 服务端转写能力。取不到时返回 `unknown`（界面显示"仅本地"而不是报错）。
final FutureProvider<RecordingInfo> recordingInfoProvider =
    FutureProvider<RecordingInfo>((ref) async {
      final api = ref.watch(recordingApiProvider);
      if (api == null) {
        return RecordingInfo.unknown;
      }
      try {
        return await api.info();
      } on ApiException {
        return RecordingInfo.unknown;
      }
    });

/// 录音列表：本地账本 + 服务端最近 100 条。
///
/// 搜索与分组在客户端做：录音是低频数据，100 条足够覆盖"最近在听什么"；
/// 服务端仍保留 `q` 参数，等数据量真的上来再切到服务端搜索。
final FutureProvider<RecordingsLibrary> recordingsLibraryProvider =
    FutureProvider<RecordingsLibrary>((ref) async {
      final store = await ref.watch(recordingStoreProvider.future);
      final local = await store.scan();
      final api = ref.watch(recordingApiProvider);
      if (api == null) {
        return RecordingsLibrary(
          local: local,
          server: const <ServerRecording>[],
          offline: true,
          error: '服务未连接：录音仍会保存在本机，连上后再上传',
        );
      }

      try {
        final page = await api.list(limit: 100);
        return RecordingsLibrary(local: local, server: page.items);
      } on ApiException catch (error) {
        return RecordingsLibrary(
          local: local,
          server: const <ServerRecording>[],
          offline: true,
          error: error.userMessage,
        );
      }
    });
