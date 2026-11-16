import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'recording_models.dart';
import 'vad_segmenter.dart';
import 'wav.dart';

/// 本地录音账本。
///
/// 目录布局：
/// ```text
/// {appSupport}/recordings/{client_id}/
///   meta.json          # 元信息 + 每段上传/转写状态（原子写）
///   seg_00000.wav      # 16kHz 单声道 PCM16
///   audio.wav          # 播放/导出用的拼接结果（按需生成）
/// ```
/// 元信息与分段落盘分开：`meta.json` 损坏时音频仍在，可以人工抢救；
/// 反过来只存数据库则杀进程后新建的记录会丢。
class RecordingStore {
  RecordingStore({required this.root});

  final Directory root;
  static final RegExp _safeId = RegExp(r'^[a-z0-9_-]{1,64}$');
  static final Random _random = Random.secure();

  static Future<RecordingStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    final store = RecordingStore(
      root: Directory('${support.path}${Platform.pathSeparator}recordings'),
    );
    await store.init();
    return store;
  }

  Future<void> init() async {
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
  }

  /// 生成一个新的本地录音（尚未落盘）。
  LocalRecording newRecording({required RecordingMode mode, DateTime? now}) {
    final startedAt = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return LocalRecording(
      clientId: _newClientId(startedAt),
      title: defaultTitle(DateTime.fromMillisecondsSinceEpoch(startedAt), mode),
      mode: mode,
      startedAt: startedAt,
    );
  }

  static String defaultTitle(DateTime time, RecordingMode mode) {
    String two(int value) => value.toString().padLeft(2, '0');
    final date =
        '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
    return '${mode == RecordingMode.realtime ? '实时录音' : '录音'} $date';
  }

  String _newClientId(int startedAt) {
    final suffix = List<String>.generate(
      12,
      (_) => _random.nextInt(36).toRadixString(36),
    ).join();
    return 'rec_${startedAt.toRadixString(36)}_$suffix';
  }

  Directory recordingDir(LocalRecording recording) =>
      Directory('${root.path}${Platform.pathSeparator}${recording.clientId}');

  File segmentFile(LocalRecording recording, LocalSegment segment) => File(
    '${recordingDir(recording).path}${Platform.pathSeparator}'
    'seg_${segment.seq.toString().padLeft(5, '0')}.wav',
  );

  File metaFile(LocalRecording recording) =>
      File('${recordingDir(recording).path}${Platform.pathSeparator}meta.json');

  File playbackFile(LocalRecording recording) =>
      File('${recordingDir(recording).path}${Platform.pathSeparator}audio.wav');

  /// 把一段 PCM 写成 WAV 并更新账本。返回新分段。
  Future<LocalSegment> appendSegment(
    LocalRecording recording,
    VadSegment segment,
  ) async {
    final dir = recordingDir(recording);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final seq = recording.nextSeq;
    final wav = buildWav(segment.pcm);
    final file = File(
      '${dir.path}${Platform.pathSeparator}seg_${seq.toString().padLeft(5, '0')}.wav',
    );
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(wav, flush: true);
    await tmp.rename(file.path);

    final local = LocalSegment(
      seq: seq,
      startMs: segment.startMs,
      endMs: segment.endMs,
      bytes: wav.length,
    );
    recording.segments.add(local);
    recording.sortSegments();
    recording.durationMs = max(recording.durationMs, segment.endMs);
    await save(recording);
    return local;
  }

  /// 原子写账本：先写临时文件再 rename，进程被杀不会留下半截 JSON。
  Future<void> save(LocalRecording recording) async {
    final dir = recordingDir(recording);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final tmp = File('${metaFile(recording).path}.tmp');
    await tmp.writeAsString(jsonEncode(recording.toJson()), flush: true);
    await tmp.rename(metaFile(recording).path);
  }

  Future<Uint8List> readSegment(
    LocalRecording recording,
    LocalSegment segment,
  ) => segmentFile(recording, segment).readAsBytes();

  /// 扫描全部本地录音，按开始时间倒序。单个 meta 损坏不影响其它记录。
  Future<List<LocalRecording>> scan() async {
    if (!await root.exists()) {
      return <LocalRecording>[];
    }

    final recordings = <LocalRecording>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!_safeId.hasMatch(name)) {
        continue;
      }
      final meta = File('${entity.path}${Platform.pathSeparator}meta.json');
      if (!await meta.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await meta.readAsString());
        if (decoded is Map<String, dynamic>) {
          final recording = LocalRecording.fromJson(decoded);
          if (recording.clientId.isNotEmpty) {
            recordings.add(recording);
          }
        }
      } on FormatException {
        // 账本损坏：跳过这一条，音频文件保留，留给人工恢复。
      } on FileSystemException {
        // 并行删除/移动时可能读不到，下一次扫描再处理。
      }
    }

    recordings.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return recordings;
  }

  /// 生成播放/导出用的整段 WAV。已存在且长度匹配时直接复用。
  Future<File> ensurePlaybackFile(LocalRecording recording) async {
    final target = playbackFile(recording);
    final segments = List<LocalSegment>.from(recording.segments)
      ..sort((a, b) => a.seq.compareTo(b.seq));
    if (segments.isEmpty) {
      throw const FileSystemException('这条录音还没有音频');
    }

    var pcmTotal = 0;
    for (final segment in segments) {
      final file = segmentFile(recording, segment);
      if (!await file.exists()) {
        throw FileSystemException('录音分段缺失', file.path);
      }
      pcmTotal += await file.length() - 44;
    }
    final expected = pcmTotal + 44;

    if (await target.exists() && await target.length() == expected) {
      return target;
    }

    // 流式写：先写头，再逐段追加 PCM。长录音（1 小时约 460MB）不能
    // 先拼成一个大 Uint8List，否则播放前就把内存吃满。
    final handle = await target.open(mode: FileMode.write);
    try {
      await handle.writeFrom(wavHeader(pcmTotal));
      for (final segment in segments) {
        final wav = await readSegment(recording, segment);
        if (wav.length > 44) {
          await handle.writeFrom(wav, 44);
        }
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
    return target;
  }

  Future<void> delete(LocalRecording recording) async {
    final dir = recordingDir(recording);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 本地占用（字节）。列表页脚与设置页都要显示。
  Future<int> diskUsage() async {
    if (!await root.exists()) {
      return 0;
    }
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // 正在写入的文件可能拿不到长度，忽略。
        }
      }
    }
    return total;
  }
}
