import 'dart:convert';
import 'dart:typed_data';

/// 录音模式。与服务端 `recording.mode` 同值。
enum RecordingMode {
  /// 边录边传，每段闭合就转写。
  realtime,

  /// 录音期间不上传，停止后整体上传。
  batch;

  String get wire => name;

  String get label => switch (this) {
    RecordingMode.realtime => '实时转写',
    RecordingMode.batch => '录完再转',
  };

  String get hint => switch (this) {
    RecordingMode.realtime => '边说边出稿，每段录完就上传',
    RecordingMode.batch => '录音期间不联网，停止后整体上传',
  };

  static RecordingMode parse(String? raw) =>
      raw == 'realtime' ? RecordingMode.realtime : RecordingMode.batch;
}

/// 服务端聚合状态。
enum RecordingStatus {
  recording,
  recorded,
  transcribing,
  ready,
  partial,
  failed;

  static RecordingStatus parse(String? raw) {
    for (final value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return RecordingStatus.recording;
  }

  String get label => switch (this) {
    RecordingStatus.recording => '录音中',
    RecordingStatus.recorded => '待转写',
    RecordingStatus.transcribing => '转写中',
    RecordingStatus.ready => '已转写',
    RecordingStatus.partial => '部分失败',
    RecordingStatus.failed => '转写失败',
  };
}

/// 分段状态。与服务端 `recording_segments.state` 同值。
enum SegmentState {
  stored,
  transcribing,
  ready,
  failed;

  static SegmentState parse(String? raw) {
    for (final value in values) {
      if (value.name == raw) {
        return value;
      }
    }
    return SegmentState.stored;
  }
}

/// 本地录音元信息。
///
/// 这是**客户端自己的账本**：音频文件与上传进度只在这里，服务端并不知道
/// 哪一段还没传。重装客户端会丢（音频仍在磁盘上但不再被索引），这是刻意取舍——
/// 权威转写稿在服务端，本地只负责"还没传完"的那部分。
class LocalRecording {
  LocalRecording({
    required this.clientId,
    required this.title,
    required this.mode,
    required this.startedAt,
    this.serverId,
    this.durationMs = 0,
    this.completed = false,
    this.lastError,
    List<LocalSegment>? segments,
  }) : segments = segments ?? <LocalSegment>[];

  /// 客户端生成的稳定 id，同时是本地目录名。
  final String clientId;
  String? serverId;
  String title;
  RecordingMode mode;
  int startedAt;
  int durationMs;
  bool completed;
  String? lastError;
  final List<LocalSegment> segments;

  int get bytes =>
      segments.fold<int>(0, (total, segment) => total + segment.bytes);

  int get uploadedCount => segments.where((segment) => segment.uploaded).length;

  bool get allUploaded =>
      serverId != null && segments.every((segment) => segment.uploaded);

  bool get hasPendingUpload =>
      serverId == null || segments.any((segment) => !segment.uploaded);

  String get transcript => segments
      .where((segment) => segment.text.trim().isNotEmpty)
      .map((segment) => segment.text.trim())
      .join('\n');

  String get preview => transcript.replaceAll(RegExp(r'\s+'), ' ');

  int get nextSeq => segments.isEmpty
      ? 0
      : segments.map((segment) => segment.seq).reduce((a, b) => a > b ? a : b) +
            1;

  LocalSegment? get lastSegment => segments.isEmpty
      ? null
      : (List<LocalSegment>.from(
          segments,
        )..sort((a, b) => a.seq.compareTo(b.seq))).last;

  int get endMs {
    final last = lastSegment;
    if (last == null) {
      return durationMs;
    }
    return last.endMs > durationMs ? last.endMs : durationMs;
  }

  void sortSegments() => segments.sort((a, b) => a.seq.compareTo(b.seq));

  Map<String, dynamic> toJson() => <String, dynamic>{
    'client_id': clientId,
    'server_id': serverId,
    'title': title,
    'mode': mode.wire,
    'started_at': startedAt,
    'duration_ms': durationMs,
    'completed': completed,
    'last_error': lastError,
    'segments': segments.map((segment) => segment.toJson()).toList(),
  };

  static LocalRecording fromJson(Map<String, dynamic> json) {
    final segments = <LocalSegment>[];
    final raw = json['segments'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          segments.add(LocalSegment.fromJson(item));
        }
      }
    }
    final recording = LocalRecording(
      clientId: json['client_id'] as String? ?? '',
      title: json['title'] as String? ?? '未命名录音',
      mode: RecordingMode.parse(json['mode'] as String?),
      startedAt: _asInt(json['started_at']),
      serverId: json['server_id'] as String?,
      durationMs: _asInt(json['duration_ms']),
      completed: json['completed'] == true,
      lastError: json['last_error'] as String?,
      segments: segments,
    )..sortSegments();
    return recording;
  }
}

/// 本地一个分段。
class LocalSegment {
  LocalSegment({
    required this.seq,
    required this.startMs,
    required this.endMs,
    required this.bytes,
    this.uploaded = false,
    this.text = '',
    this.state = SegmentState.stored,
    this.error,
  });

  final int seq;
  final int startMs;
  final int endMs;

  /// WAV 文件大小（含 44 字节头）。
  final int bytes;
  bool uploaded;
  String text;
  SegmentState state;
  String? error;

  double get durationMs => (endMs - startMs).toDouble();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'seq': seq,
    'start_ms': startMs,
    'end_ms': endMs,
    'bytes': bytes,
    'uploaded': uploaded,
    'text': text,
    'state': state.name,
    'error': error,
  };

  static LocalSegment fromJson(Map<String, dynamic> json) => LocalSegment(
    seq: _asInt(json['seq']),
    startMs: _asInt(json['start_ms']),
    endMs: _asInt(json['end_ms']),
    bytes: _asInt(json['bytes']),
    uploaded: json['uploaded'] == true,
    text: json['text'] as String? ?? '',
    state: SegmentState.parse(json['state'] as String?),
    error: json['error'] as String?,
  );
}

/// 服务端录音元信息。
class ServerRecording {
  const ServerRecording({
    required this.id,
    required this.clientRecordingId,
    required this.title,
    required this.mode,
    required this.status,
    required this.durationMs,
    required this.bytes,
    required this.segmentCount,
    required this.readyCount,
    required this.preview,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String clientRecordingId;
  final String title;
  final RecordingMode mode;
  final RecordingStatus status;
  final int durationMs;
  final int bytes;
  final int segmentCount;
  final int readyCount;
  final String preview;
  final int createdAt;
  final int updatedAt;

  static ServerRecording fromJson(Map<String, dynamic> json) => ServerRecording(
    id: json['id'] as String? ?? '',
    clientRecordingId: json['client_recording_id'] as String? ?? '',
    title: json['title'] as String? ?? '未命名录音',
    mode: RecordingMode.parse(json['mode'] as String?),
    status: RecordingStatus.parse(json['status'] as String?),
    durationMs: _asInt(json['duration_ms']),
    bytes: _asInt(json['bytes']),
    segmentCount: _asInt(json['segment_count']),
    readyCount: _asInt(json['ready_count']),
    preview: json['preview'] as String? ?? '',
    createdAt: _asInt(json['created_at']),
    updatedAt: _asInt(json['updated_at']),
  );
}

/// 服务端分段。
class ServerSegment {
  const ServerSegment({
    required this.seq,
    required this.startMs,
    required this.endMs,
    required this.bytes,
    required this.text,
    required this.state,
    this.error,
  });

  final int seq;
  final int startMs;
  final int endMs;
  final int bytes;
  final String text;
  final SegmentState state;
  final String? error;

  static ServerSegment fromJson(Map<String, dynamic> json) => ServerSegment(
    seq: _asInt(json['seq']),
    startMs: _asInt(json['start_ms']),
    endMs: _asInt(json['end_ms']),
    bytes: _asInt(json['bytes']),
    text: json['text'] as String? ?? '',
    state: SegmentState.parse(json['state'] as String?),
    error: json['error'] as String?,
  );
}

/// 录音总结的生成状态。
enum SummaryStatus {
  none,
  pending,
  running,
  ready,
  failed;

  static SummaryStatus parse(String? raw) => switch (raw) {
    'pending' => SummaryStatus.pending,
    'running' => SummaryStatus.running,
    'ready' => SummaryStatus.ready,
    'failed' => SummaryStatus.failed,
    _ => SummaryStatus.none,
  };

  String get wire => name;

  bool get isActive =>
      this == SummaryStatus.pending || this == SummaryStatus.running;
}

/// 总结形式。
enum SummaryStyle {
  minutes,
  brief,
  detailed;

  static SummaryStyle parse(String? raw) => switch (raw) {
    'minutes' => SummaryStyle.minutes,
    'detailed' => SummaryStyle.detailed,
    _ => SummaryStyle.brief,
  };

  String get wire => name;

  String get label => switch (this) {
    SummaryStyle.minutes => '会议纪要式',
    SummaryStyle.brief => '简短摘要',
    SummaryStyle.detailed => '详细分段摘要',
  };

  String get hint => switch (this) {
    SummaryStyle.minutes => '概要 + 关键要点 + 待办/结论',
    SummaryStyle.brief => '3–5 句话说明录音内容',
    SummaryStyle.detailed => '按话题分段归纳，篇幅更长',
  };
}

/// 总结语音的合成状态。
enum SummaryAudioStatus {
  none,
  pending,
  running,
  ready,
  failed;

  static SummaryAudioStatus parse(String? raw) => switch (raw) {
    'pending' => SummaryAudioStatus.pending,
    'running' => SummaryAudioStatus.running,
    'ready' => SummaryAudioStatus.ready,
    'failed' => SummaryAudioStatus.failed,
    _ => SummaryAudioStatus.none,
  };

  bool get isActive =>
      this == SummaryAudioStatus.pending || this == SummaryAudioStatus.running;
}

/// 服务端保存的总结与总结语音状态。
class RecordingSummary {
  const RecordingSummary({
    this.status = SummaryStatus.none,
    this.text = '',
    this.style,
    this.stylePreference = SummaryStyle.brief,
    this.error,
    this.model,
    this.updatedAt,
    this.audioStatus = SummaryAudioStatus.none,
    this.audioError,
    this.audioBytes = 0,
    this.audioFormat,
    this.audioUpdatedAt,
    this.audioTruncated = false,
  });

  final SummaryStatus status;
  final String text;

  /// 当前正文实际使用的形式；未生成时为 null。
  final SummaryStyle? style;

  /// 用户选中的下一版形式；可能与 [style] 不同，需点「重新生成」才生效。
  final SummaryStyle stylePreference;
  final String? error;
  final String? model;
  final int? updatedAt;
  final SummaryAudioStatus audioStatus;
  final String? audioError;
  final int audioBytes;
  final String? audioFormat;
  final int? audioUpdatedAt;
  final bool audioTruncated;

  bool get isReady => status == SummaryStatus.ready && text.trim().isNotEmpty;

  static RecordingSummary fromJson(
    Map<String, dynamic> json,
  ) => RecordingSummary(
    status: SummaryStatus.parse(json['status'] as String?),
    text: json['text'] as String? ?? '',
    style: json['style'] == null
        ? null
        : SummaryStyle.parse(json['style'] as String?),
    stylePreference: SummaryStyle.parse(json['style_preference'] as String?),
    error: json['error'] as String?,
    model: json['model'] as String?,
    updatedAt: json['updated_at'] == null ? null : _asInt(json['updated_at']),
    audioStatus: SummaryAudioStatus.parse(json['audio_status'] as String?),
    audioError: json['audio_error'] as String?,
    audioBytes: _asInt(json['audio_bytes']),
    audioFormat: json['audio_format'] as String?,
    audioUpdatedAt: json['audio_updated_at'] == null
        ? null
        : _asInt(json['audio_updated_at']),
    audioTruncated: json['audio_truncated'] == true,
  );
}

/// 总结语音的波形峰值：`0..255` 的线性幅度，按时间顺序排列。
///
/// 服务端固定给 480 桶；接口不可用、字段缺失或数组为空时 [peaks] 为空，
/// 播放器据此退回原来的进度条。
class SummaryAudioPeaks {
  SummaryAudioPeaks({this.version, Uint8List? peaks})
    : peaks = peaks ?? Uint8List(0);

  /// 语音版本（`summary.audio_updated_at`）：重生成语音后会变，缓存据此失效。
  final int? version;
  final Uint8List peaks;

  bool get isUsable => peaks.isNotEmpty;

  /// 容错解析：缺字段、非数组、越界值都只影响对应桶，不抛异常。
  static SummaryAudioPeaks fromJson(Map<String, dynamic> json) {
    final version = json['version'] == null ? null : _asInt(json['version']);
    final raw = json['peaks'];
    if (raw is! List || raw.isEmpty) {
      return SummaryAudioPeaks(version: version);
    }
    final peaks = Uint8List(raw.length);
    for (var index = 0; index < raw.length; index++) {
      final value = raw[index];
      if (value is num) {
        peaks[index] = value.round().clamp(0, 255);
      }
    }
    return SummaryAudioPeaks(version: version, peaks: peaks);
  }
}

class ServerRecordingDetail {
  const ServerRecordingDetail({
    required this.recording,
    required this.segments,
    this.summary = const RecordingSummary(),
  });

  final ServerRecording recording;
  final List<ServerSegment> segments;
  final RecordingSummary summary;

  static ServerRecordingDetail fromJson(Map<String, dynamic> json) {
    final recording = ServerRecording.fromJson(
      (json['recording'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
    );
    final raw = json['segments'];
    final segments = <ServerSegment>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          segments.add(ServerSegment.fromJson(item));
        }
      }
    }
    final summary = RecordingSummary.fromJson(
      (json['summary'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
    );
    return ServerRecordingDetail(
      recording: recording,
      segments: segments,
      summary: summary,
    );
  }
}

class RecordingPage {
  const RecordingPage({required this.items, this.nextCursor});

  final List<ServerRecording> items;
  final String? nextCursor;

  static RecordingPage fromJson(Map<String, dynamic> json) {
    final items = <ServerRecording>[];
    final raw = json['items'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          items.add(ServerRecording.fromJson(item));
        }
      }
    }
    return RecordingPage(
      items: items,
      nextCursor: json['next_cursor'] as String?,
    );
  }
}

/// 服务端转写能力与配额。
class RecordingInfo {
  const RecordingInfo({
    required this.asrEnabled,
    required this.asrAvailable,
    this.asrModel,
    required this.maxSegmentBytes,
    required this.maxDurationMs,
    required this.maxTotalBytes,
    this.summaryAvailable = false,
    this.summaryModel,
    this.summaryDefaultStyle = SummaryStyle.brief,
    this.ttsEnabled = false,
    this.ttsAvailable = false,
    this.ttsModel,
    this.ttsVoice,
  });

  final bool asrEnabled;
  final bool asrAvailable;
  final String? asrModel;
  final int maxSegmentBytes;
  final int maxDurationMs;
  final int maxTotalBytes;
  final bool summaryAvailable;
  final String? summaryModel;
  final SummaryStyle summaryDefaultStyle;
  final bool ttsEnabled;
  final bool ttsAvailable;
  final String? ttsModel;
  final String? ttsVoice;

  static const RecordingInfo unknown = RecordingInfo(
    asrEnabled: false,
    asrAvailable: false,
    maxSegmentBytes: 32 * 1024 * 1024,
    maxDurationMs: 4 * 60 * 60 * 1000,
    maxTotalBytes: 1024 * 1024 * 1024,
  );

  static RecordingInfo fromJson(Map<String, dynamic> json) => RecordingInfo(
    asrEnabled: json['asr_enabled'] == true,
    asrAvailable: json['asr_available'] == true,
    asrModel: json['asr_model'] as String?,
    maxSegmentBytes: _asInt(json['max_segment_bytes']),
    maxDurationMs: _asInt(json['max_duration_ms']),
    maxTotalBytes: _asInt(json['max_total_bytes']),
    summaryAvailable: json['summary_available'] == true,
    summaryModel: json['summary_model'] as String?,
    summaryDefaultStyle: SummaryStyle.parse(
      json['summary_default_style'] as String?,
    ),
    ttsEnabled: json['tts_enabled'] == true,
    ttsAvailable: json['tts_available'] == true,
    ttsModel: json['tts_model'] as String?,
    ttsVoice: json['tts_voice'] as String?,
  );
}

/// 本地账本的读取结果：一条录音 + 它是否还有未上传分段。
class LocalRecordingSummary {
  const LocalRecordingSummary({required this.recording, required this.dirty});

  final LocalRecording recording;
  final bool dirty;
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse('$value') ?? 0;
}

/// 列表页的数据源：本地账本 + 服务端列表。
///
/// 本地账本负责"还没传完的"，服务端负责"已经归档的"。
/// 服务不可达时仍然返回本地部分，界面显示离线而不是空白。
class RecordingsLibrary {
  const RecordingsLibrary({
    required this.local,
    required this.server,
    this.offline = false,
    this.error,
  });

  final List<LocalRecording> local;
  final List<ServerRecording> server;
  final bool offline;
  final String? error;

  LocalRecording? localFor(String clientId) {
    for (final recording in local) {
      if (recording.clientId == clientId) {
        return recording;
      }
    }
    return null;
  }

  ServerRecording? serverForClient(String clientId) {
    for (final recording in server) {
      if (recording.clientRecordingId == clientId) {
        return recording;
      }
    }
    return null;
  }

  /// 只在服务端存在、本地没有账本的录音（换设备或在另一台客户端录的）。
  List<ServerRecording> get serverOnly => server
      .where((item) => localFor(item.clientRecordingId) == null)
      .toList(growable: false);
}

/// 便于本地调试与导出的完整 JSON。
String encodeRecordingJson(LocalRecording recording) =>
    const JsonEncoder.withIndent('  ').convert(recording.toJson());
