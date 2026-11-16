import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api_error.dart';
import 'audio_capture.dart';
import 'recording_foreground.dart';
import 'recording_models.dart';
import 'recording_providers.dart';
import 'recording_settings.dart';
import 'recording_store.dart';
import 'recording_uploader.dart';
import 'vad_segmenter.dart';
import 'wav.dart';

enum RecordingPhase { idle, recording, paused, saving }

/// 全局录音状态。
///
/// 录音不随页面销毁：用户切页、切项目、缩窗口都继续录，
/// 顶部常驻状态条与列表页都从这一份状态读。
class RecordingSessionState {
  const RecordingSessionState({
    required this.phase,
    this.recording,
    this.elapsedMs = 0,
    this.level = 0,
    this.levels = const <double>[],
    this.error,
  });

  const RecordingSessionState.idle()
    : phase = RecordingPhase.idle,
      recording = null,
      elapsedMs = 0,
      level = 0,
      levels = const <double>[],
      error = null;

  final RecordingPhase phase;
  final LocalRecording? recording;
  final int elapsedMs;
  final double level;

  /// 最近约 6 秒的电平历史（60ms 一帧、上限 96 槽），供波形绘制。
  final List<double> levels;
  final String? error;

  bool get active => phase != RecordingPhase.idle;

  bool get paused => phase == RecordingPhase.paused;

  bool get saving => phase == RecordingPhase.saving;

  RecordingSessionState copyWith({
    RecordingPhase? phase,
    LocalRecording? recording,
    int? elapsedMs,
    double? level,
    List<double>? levels,
    String? error,
    bool clearError = false,
    bool clearRecording = false,
  }) => RecordingSessionState(
    phase: phase ?? this.phase,
    recording: clearRecording ? null : (recording ?? this.recording),
    elapsedMs: elapsedMs ?? this.elapsedMs,
    level: level ?? this.level,
    levels: levels ?? this.levels,
    error: clearError ? null : (error ?? this.error),
  );
}

final NotifierProvider<RecordingController, RecordingSessionState>
recordingControllerProvider =
    NotifierProvider<RecordingController, RecordingSessionState>(
      RecordingController.new,
    );

class RecordingController extends Notifier<RecordingSessionState> {
  Timer? _ticker;
  StreamSubscription<dynamic>? _subscription;
  VadSegmenter? _segmenter;
  AudioCapture? _capture;
  RecordingStore? _store;
  RecordingUploader? _uploader;
  LocalRecording? _recording;

  /// 波形槽位历史上限，与 `RecordingWaveform` 的自适应上限一致。
  static const int _maxLevelSlots = 96;

  /// 快起慢落：起音系数大、回落系数小。既有冲击感又不闪烁。
  static const double _attack = 0.6;
  static const double _release = 0.12;

  final Stopwatch _stopwatch = Stopwatch();
  int _accumulatedMs = 0;
  double _level = 0;
  double _levelTarget = 0;
  bool _disposed = false;

  /// 分段写盘串行化：VAD 回调不等待 IO，停止时必须知道"写完了没有"。
  Future<void> _segmentWrites = Future<void>.value();

  @override
  RecordingSessionState build() {
    ref.onDispose(() {
      _disposed = true;
      _ticker?.cancel();
      _subscription?.cancel();
    });
    return const RecordingSessionState.idle();
  }

  bool get _uploadEnabled =>
      ref.read(recordingPreferencesProvider).value?.uploadEnabled ?? false;

  /// 原生保活（只有 Android 真正实现，其余平台 no-op）。
  ///
  /// 与采集同生共死：采集在跑才需要前台服务，暂停/停止就撤掉通知；
  /// 它失败只降级成"仅前台可录"，绝不反过来中断录音。
  RecordingForeground get _foreground =>
      ref.read(recordingForegroundProvider);

  /// 开始录音。权限被拒时返回 false，并在 `state.error` 里给出可执行提示。
  Future<bool> start(RecordingMode mode) async {
    if (state.active) {
      return false;
    }

    state = state.copyWith(clearError: true);
    try {
      final capture = ref.read(audioCaptureProvider);
      final allowed = await capture.requestPermission();
      if (!allowed) {
        state = state.copyWith(
          error: '没有麦克风权限：到「系统设置 → 隐私与安全性 → 麦克风」里允许本应用，然后重试',
        );
        return false;
      }

      final store = await ref.read(recordingStoreProvider.future);
      final recording = store.newRecording(mode: mode);
      await store.save(recording);

      // 先登记再启动采集：start 失败时 catch 里才知道要清掉这条空账本。
      _store = store;
      _recording = recording;
      final stream = await capture.start();

      _capture = capture;
      _segmenter = VadSegmenter(onSegment: _enqueueSegment);
      _subscription = stream.listen(
        (chunk) {
          if (chunk.isEmpty) {
            return;
          }
          _segmenter?.add(chunk);
          _levelTarget = visualLevel(peakLevel(chunk));
        },
        onError: (Object error) {
          _fail('录音流中断：$error');
        },
      );

      _stopwatch
        ..reset()
        ..start();
      _accumulatedMs = 0;
      _level = 0;
      _levelTarget = 0;
      _ticker?.cancel();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 60),
        (_) => _tick(),
      );

      state = RecordingSessionState(
        phase: RecordingPhase.recording,
        recording: recording,
        levels: const <double>[],
      );
      // 采集真的跑起来了再挂保活：Android 的前台服务要等 startForeground
      // 成功才算生效，提前挂只会留一条"在录却没数据"的通知。
      unawaited(_foreground.start());
      _refreshLibrary();
      return true;
    } on AudioCaptureException catch (error) {
      unawaited(_foreground.stop());
      await _discardEmptyRecording();
      state = state.copyWith(error: error.message);
      return false;
    } on Object catch (error) {
      unawaited(_foreground.stop());
      await _discardEmptyRecording();
      state = state.copyWith(error: '无法开始录音：$error');
      return false;
    }
  }

  /// 开始失败时把刚建的空录音账本清掉，避免列表里留下一条没有音频的记录。
  Future<void> _discardEmptyRecording() async {
    final recording = _recording;
    if (recording != null && recording.segments.isEmpty) {
      await _store?.delete(recording);
      _recording = null;
    }
  }

  Future<void> pause() async {
    if (state.phase != RecordingPhase.recording) {
      return;
    }
    _segmenter?.flush();
    await _segmentWrites;
    try {
      await _capture?.pause();
    } on AudioCaptureException catch (error) {
      _fail(error.message);
      return;
    }
    _stopwatch.stop();
    _accumulatedMs += _stopwatch.elapsedMilliseconds;
    _stopwatch.reset();
    _ticker?.cancel();
    // 暂停时不采集了，前台服务与常驻通知一起撤掉；恢复时再挂回来。
    unawaited(_foreground.stop());
    state = state.copyWith(
      phase: RecordingPhase.paused,
      elapsedMs: _accumulatedMs,
      level: 0,
    );
  }

  Future<void> resume() async {
    if (state.phase != RecordingPhase.paused) {
      return;
    }
    try {
      await _capture?.resume();
    } on AudioCaptureException catch (error) {
      _fail(error.message);
      return;
    }
    _stopwatch
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 60), (_) => _tick());
    unawaited(_foreground.start());
    state = state.copyWith(phase: RecordingPhase.recording, clearError: true);
  }

  /// 停止并保存。返回保存下来的录音，供界面跳详情。
  Future<LocalRecording?> stop() async {
    final recording = _recording;
    if (recording == null || state.phase == RecordingPhase.idle) {
      return null;
    }

    state = state.copyWith(phase: RecordingPhase.saving);
    // 先断开采集流再收段：否则收段等待写盘期间还会有新帧进来，
    // 关门那一刻的声音会被算进下一段、然后随订阅一起丢掉。
    await _subscription?.cancel();
    _subscription = null;
    _segmenter?.flush();
    await _segmentWrites;

    try {
      await _capture?.stop();
    } on AudioCaptureException catch (error) {
      // 停止失败也要把已录部分留住：后面照常落账本。
      _fail(error.message);
    }

    // 采集已停，前台服务必须同步撤掉；即使 stop 抛过异常也要走这里（上面已捕获）。
    unawaited(_foreground.stop());

    _ticker?.cancel();
    _stopwatch.stop();
    final elapsed = _accumulatedMs + _stopwatch.elapsedMilliseconds;

    _recording = null;
    _segmenter = null;
    _stopwatch.reset();
    _accumulatedMs = 0;
    _level = 0;
    _levelTarget = 0;

    if (recording.segments.isEmpty) {
      // 一句都没录到（刚点就停 / 权限问题）：不留一条空录音。
      await _store?.delete(recording);
      state = const RecordingSessionState.idle().copyWith(
        error: '没有录到声音，这条录音已丢弃',
      );
      _refreshLibrary();
      return null;
    }

    recording.completed = true;
    recording.durationMs = max(recording.endMs, elapsed);
    await _store?.save(recording);

    state = const RecordingSessionState.idle();
    _refreshLibrary();

    if (_uploadEnabled) {
      unawaited(_sync(recording));
    }
    return recording;
  }

  /// 系统进入后台/即将退出时，把当前正在说的那段收尾落盘。
  ///
  /// 这里**不停止录音**：iOS/macOS 上的暂停语义不同，贸然 stop 会让
  /// 回到前台后无法继续。只保证已经说出口的内容先写到磁盘。
  Future<void> flushPartial() async {
    if (state.phase != RecordingPhase.recording) {
      return;
    }
    _segmenter?.flush();
    await _segmentWrites;
  }

  /// 重启后恢复：把被中断的录音标记为已完成，并续传尚未上传的分段。
  Future<void> restore() async {
    try {
      final store = await ref.read(recordingStoreProvider.future);
      _store = store;
      final recordings = await store.scan();

      for (final recording in recordings) {
        if (recording.segments.isEmpty) {
          // 上次退出时还没录到任何一段：没有保留价值。
          await store.delete(recording);
          continue;
        }
        if (!recording.completed) {
          recording.completed = true;
          recording.durationMs = max(recording.durationMs, recording.endMs);
          recording.lastError ??= '录音被中断，已保存已录部分';
          await store.save(recording);
        }
      }

      // 偏好是异步读出来的：启动时同步 getter 可能还是 null，
      // 那会让"上次没传完的录音"永远不续传。
      var enabled = false;
      try {
        enabled = (await ref.read(recordingPreferencesProvider.future))
            .uploadEnabled;
      } on Object {
        enabled = false;
      }

      if (enabled) {
        for (final recording in recordings) {
          if (recording.completed && recording.hasPendingUpload) {
            unawaited(_sync(recording));
          }
        }
      }
      _refreshLibrary();
    } on Object {
      // 恢复失败不该拦住启动：本地文件还在，下次打开再试。
    }
  }

  /// 上传所有已结束但还没传完的录音（设置里打开开关时调用）。
  Future<void> syncPending() async {
    final store = await ref.read(recordingStoreProvider.future);
    _store = store;
    final recordings = await store.scan();
    for (final recording in recordings) {
      if (recording.completed && recording.hasPendingUpload) {
        unawaited(_sync(recording));
      }
    }
  }

  /// 清理"已经完整上传"的本地音频。
  ///
  /// 删的是本地目录，服务端归档与转写稿都还在；之后这条录音会从服务端列表
  /// 以「另一台设备录的」形式继续可见，播放时按需下载。
  Future<int> clearUploadedAudio() async {
    final RecordingStore store =
        _store ?? await ref.read(recordingStoreProvider.future);
    _store = store;
    final recordings = await store.scan();
    var removed = 0;
    for (final recording in recordings) {
      if (recording.serverId != null && recording.allUploaded) {
        await store.delete(recording);
        removed++;
      }
    }
    _refreshLibrary();
    return removed;
  }

  /// 详情页的「重试失败段」。
  Future<void> retry(LocalRecording recording) async {
    final uploader = _ensureUploader();
    if (uploader == null) {
      return;
    }
    try {
      await uploader.retry(recording);
    } on ApiException catch (error) {
      recording.lastError = error.userMessage;
      await _store?.save(recording);
    } finally {
      _refreshLibrary();
    }
  }

  Future<void> delete(LocalRecording recording) async {
    final RecordingStore store =
        _store ?? await ref.read(recordingStoreProvider.future);
    final uploader = _ensureUploader();
    try {
      await uploader?.deleteRemote(recording);
    } on ApiException {
      // 服务端删除失败不该阻止本地清理：下次仍可从详情重试。
    }
    await store.delete(recording);
    _refreshLibrary();
  }

  Future<void> rename(LocalRecording recording, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final uploader = _ensureUploader();
    if (uploader != null) {
      try {
        await uploader.updateTitle(recording, trimmed);
        _refreshLibrary();
        return;
      } on ApiException {
        // 离线时只改本地，连上后 sync 会带过去。
      }
    }
    recording.title = trimmed;
    await _store?.save(recording);
    _refreshLibrary();
  }

  void _tick() {
    if (_recording == null || state.phase == RecordingPhase.paused) {
      return;
    }
    // 向上取攻击系数、向下取释放系数：起音立刻顶上去，回落慢慢收。
    final coefficient = _levelTarget > _level ? _attack : _release;
    _level += (_levelTarget - _level) * coefficient;
    final elapsed = _accumulatedMs + _stopwatch.elapsedMilliseconds;
    final levels = <double>[...state.levels, _level];
    if (levels.length > _maxLevelSlots) {
      levels.removeRange(0, levels.length - _maxLevelSlots);
    }
    state = state.copyWith(elapsedMs: elapsed, level: _level, levels: levels);
  }

  void _enqueueSegment(VadSegment segment) {
    _segmentWrites = _segmentWrites.then((_) async {
      final recording = _recording;
      final store = _store;
      if (recording == null || store == null) {
        return;
      }
      try {
        await store.appendSegment(recording, segment);
        if (!_disposed) {
          state = state.copyWith(recording: recording);
          _refreshLibrary();
        }
        final uploader = _uploadEnabled ? _ensureUploader() : null;
        if (uploader != null && recording.mode == RecordingMode.realtime) {
          unawaited(_sync(recording));
        }
      } on Object catch (error) {
        _fail('保存录音分段失败：$error');
      }
    });
  }

  Future<void> _sync(LocalRecording recording) async {
    final uploader = _ensureUploader();
    if (uploader == null) {
      return;
    }
    try {
      await uploader.sync(recording);
    } on ApiException catch (error) {
      _fail(error.userMessage);
    } on Object catch (error) {
      _fail('上传失败：$error');
    } finally {
      _refreshLibrary();
    }
  }

  RecordingUploader? _ensureUploader() {
    final store = _store;
    if (store == null) {
      return null;
    }
    final api = ref.read(recordingApiProvider);
    if (api == null) {
      return null;
    }
    return _uploader ??= RecordingUploader(
      api: api,
      store: store,
      onChanged: (recording) {
        if (_disposed) {
          return;
        }
        if (identical(recording, _recording)) {
          state = state.copyWith(recording: recording, clearError: true);
        }
        _refreshLibrary();
      },
    );
  }

  void _refreshLibrary() {
    if (_disposed) {
      return;
    }
    ref.invalidate(recordingsLibraryProvider);
  }

  void _fail(String message) {
    if (_disposed) {
      return;
    }
    state = state.copyWith(error: message);
  }
}
