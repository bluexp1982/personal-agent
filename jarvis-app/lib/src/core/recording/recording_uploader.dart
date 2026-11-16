import 'dart:async';

import '../api_error.dart';
import 'recording_api.dart';
import 'recording_models.dart';
import 'recording_store.dart';

/// 上传与转写调度。
///
/// 两条路径共用同一份实现，差别只在"什么时候调用"：
/// - 实时：每闭合一段调用一次 `sync`，`completed=false` 时只传分段；
/// - 批量：录音结束时调用一次，分段传完后 `complete` 触发整体转写。
///
/// 幂等靠三层保证：服务端 `client_recording_id` 唯一、`(recording_id, seq)`
/// 主键、本地 `uploaded` 标记。任一层失效都不会产生重复文本。
class RecordingUploader {
  RecordingUploader({
    required this.api,
    required this.store,
    this.onChanged,
    this.pollInterval = const Duration(seconds: 1),
    this.pollAttempts = 120,
  });

  final RecordingApi api;
  final RecordingStore store;

  /// 每次进度变化后回调，供控制器刷新界面。
  final void Function(LocalRecording recording)? onChanged;
  final Duration pollInterval;
  final int pollAttempts;

  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  bool get isBusy => _inFlight.isNotEmpty;

  /// 同步一条录音。
  ///
  /// 调用会**串行排队**而不是被丢弃：实时模式下每闭合一段就调一次，
  /// 如果第一次还没传完就直接复用旧 Future，最后一段会永远漏掉。
  /// 排队后每一轮都会重新扫描未上传的分段，停止时再调一次就能收尾。
  Future<void> sync(LocalRecording recording) {
    final previous = _inFlight[recording.clientId];
    // 上一轮失败不能让后面的排队轮次直接跳过：录音还在继续，
    // 新闭合的分段仍然值得再试一次。
    final base = previous == null
        ? Future<void>.value()
        : previous.catchError((Object _) {});
    late final Future<void> tracked;
    tracked = base.then((_) => _syncInner(recording)).whenComplete(() {
      if (identical(_inFlight[recording.clientId], tracked)) {
        _inFlight.remove(recording.clientId);
      }
    });
    _inFlight[recording.clientId] = tracked;
    return tracked;
  }

  Future<void> _syncInner(LocalRecording recording) async {
    recording.lastError = null;
    try {
      await _ensureServerRecording(recording);
      final serverId = recording.serverId!;

      final pending = List<LocalSegment>.from(recording.segments)
        ..sort((a, b) => a.seq.compareTo(b.seq));
      for (final segment in pending) {
        if (segment.uploaded) {
          continue;
        }
        final bytes = await store.readSegment(recording, segment);
        final uploaded = await _withRetry(
          () => api.uploadSegment(
            id: serverId,
            seq: segment.seq,
            startMs: segment.startMs,
            endMs: segment.endMs,
            bytes: bytes,
          ),
        );
        segment.uploaded = true;
        segment.text = uploaded.text;
        segment.state = uploaded.state;
        segment.error = uploaded.error;
        await store.save(recording);
        onChanged?.call(recording);
      }

      if (!recording.completed) {
        return;
      }

      var detail = await _withRetry(
        () => api.complete(serverId, durationMs: recording.durationMs),
      );
      _applyDetail(recording, detail);
      await store.save(recording);
      onChanged?.call(recording);

      // 批量转写在服务端后台跑：轮询到终态即可，不占用上传连接。
      for (var attempt = 0; attempt < pollAttempts; attempt++) {
        if (_isTerminal(detail.recording.status)) {
          return;
        }
        await Future<void>.delayed(pollInterval);
        detail = await _withRetry(() => api.detail(serverId));
        _applyDetail(recording, detail);
        await store.save(recording);
        onChanged?.call(recording);
      }
    } on ApiException catch (error) {
      // 服务端记录被删掉了（例如在另一台设备清理过）：下一次 sync 重新创建，
      // 不要拿着失效的 serverId 永远 404。
      if (error.code == 'recording_not_found') {
        recording.serverId = null;
      }
      recording.lastError = error.userMessage;
      await store.save(recording);
      onChanged?.call(recording);
      rethrow;
    } on Object catch (error) {
      recording.lastError = '上传失败：$error';
      await store.save(recording);
      onChanged?.call(recording);
      rethrow;
    }
  }

  Future<void> _ensureServerRecording(LocalRecording recording) async {
    if (recording.serverId != null) {
      return;
    }
    final server = await _withRetry(
      () => api.create(
        clientId: recording.clientId,
        title: recording.title,
        mode: recording.mode,
      ),
    );
    recording.serverId = server.id;
    await store.save(recording);
    onChanged?.call(recording);
  }

  /// 重试失败分段（服务端把它们重新排入转写队列）。
  Future<void> retry(LocalRecording recording) async {
    await _ensureServerRecording(recording);
    final serverId = recording.serverId!;
    var detail = await _withRetry(() => api.retry(serverId));
    _applyDetail(recording, detail);
    await store.save(recording);
    onChanged?.call(recording);

    for (var attempt = 0; attempt < pollAttempts; attempt++) {
      if (_isTerminal(detail.recording.status)) {
        return;
      }
      await Future<void>.delayed(pollInterval);
      detail = await _withRetry(() => api.detail(serverId));
      _applyDetail(recording, detail);
      await store.save(recording);
      onChanged?.call(recording);
    }
  }

  Future<void> deleteRemote(LocalRecording recording) async {
    final serverId = recording.serverId;
    if (serverId == null) {
      return;
    }
    await api.delete(serverId);
  }

  Future<void> updateTitle(LocalRecording recording, String title) async {
    recording.title = title;
    await store.save(recording);
    final serverId = recording.serverId;
    if (serverId != null) {
      await api.rename(serverId, title);
    }
    onChanged?.call(recording);
  }

  void _applyDetail(LocalRecording recording, ServerRecordingDetail detail) {
    final bySeq = <int, ServerSegment>{
      for (final segment in detail.segments) segment.seq: segment,
    };
    for (final segment in recording.segments) {
      final remote = bySeq[segment.seq];
      if (remote == null) {
        continue;
      }
      segment.uploaded = true;
      segment.text = remote.text;
      segment.state = remote.state;
      segment.error = remote.error;
    }
    if (detail.recording.title.isNotEmpty) {
      recording.title = detail.recording.title;
    }
  }

  bool _isTerminal(RecordingStatus status) => switch (status) {
    RecordingStatus.ready ||
    RecordingStatus.partial ||
    RecordingStatus.failed ||
    // 未开启转写时 complete 后就是 recorded：不会有文本，再等也不会变。
    RecordingStatus.recorded => true,
    _ => false,
  };

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } on ApiException catch (error) {
        final last = attempt >= 2;
        if (!error.retryable || last) {
          rethrow;
        }
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }
}
