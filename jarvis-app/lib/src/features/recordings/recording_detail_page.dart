import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_error.dart';
import '../../core/artifact_exporter.dart';
import '../../core/design/app_palette.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_controller.dart';
import '../../core/ui/agent_menu.dart';
import '../../core/recording/recording_formatters.dart';
import '../../core/recording/recording_models.dart';
import '../../core/recording/recording_providers.dart';
import '../../core/recording/recording_timeline.dart';
import '../../core/recording/waveform_peaks.dart';
import '../../core/ui/app_page_scaffold.dart';
import '../../core/ui/mobile_top_bar.dart';
import '../../core/ui/shell_icon_button.dart';
import '../shell/embedded_toolbar.dart';
import '../shell/pane_surface.dart';
import '../shell/shell_layout_state.dart';
import 'recording_status_chip.dart';
import 'recording_summary_tab.dart';
import 'waveform_timeline.dart';

/// 详情页「更多」浮层宽度。定值而不是跟着图标走，与全站菜单一致。
const double kRecordingMenuWidth = 220;

/// 播放器倍速浮层宽度：三个短选项，不需要「更多」那么宽。
const double _kSpeedMenuWidth = 120;

/// 一条录音的详情：播放器 + 带时间戳的转写稿。
///
/// 本地录音与服务端独有录音共用这一页；差别只在音频从哪来、
/// 删除/重命名走本地账本还是直接调接口。
///
/// [embedded] 为真时嵌在宽屏中栏：不画 AppBar，改用三栏统一的细栏头。
/// 内嵌形态没有返回按钮（左栏始终可见，换页是从左栏点过去的），
/// 删掉这条录音之后去哪交给外壳（[onDeleted]）；
/// 且绝不能 `Navigator.pop`——那会把整个窗口的路由弹掉。
class RecordingDetailPage extends ConsumerStatefulWidget {
  const RecordingDetailPage({
    super.key,
    this.local,
    this.server,
    this.embedded = false,
    this.onDeleted,
  });

  final LocalRecording? local;
  final ServerRecording? server;

  final bool embedded;

  /// 删除成功后的收尾。宽屏下由外壳切回列表并从历史里剪掉这一页。
  final VoidCallback? onDeleted;

  @override
  ConsumerState<RecordingDetailPage> createState() =>
      _RecordingDetailPageState();
}

class _RecordingDetailPageState extends ConsumerState<RecordingDetailPage>
    with SingleTickerProviderStateMixin {
  /// 栏头图标按钮的统一样式：命中区 24、8dp 圆角方形、零内边距。
  ///
  /// 内嵌时这一行要与左右两栏的图标落在同一条水平线上，Material 默认 48 的
  /// 命中区会把 40 高的栏头顶破。
  static final ButtonStyle _headerButtonStyle = shellIconButtonStyle(
    minimumSize: const Size.square(kPaneHeaderButtonSize),
  );

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _playerSubs =
      <StreamSubscription<dynamic>>[];
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final GlobalKey<RecordingSummaryPlayerState> _summaryPlayerKey =
      GlobalKey<RecordingSummaryPlayerState>();

  File? _audioFile;

  /// 整段音频的峰值（0..255）。null 表示还在算或不可用，播放器保留旧进度条。
  Uint8List? _peaks;

  String? _loadError;
  String? _actionError;
  ServerRecordingDetail? _remote;
  bool _loading = true;
  bool _busy = false;
  Timer? _poll;
  Timer? _waitServer;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _speed = 1;

  /// 播放到结尾后 `positionStream` 会停在最后一段的音频末尾，而不是录制时间轴
  /// 的终点：音频是"只保留说话段"的紧凑 WAV，时间轴上还有静音间隙。
  /// 这个标记让进度条在播完时明确走到 100%。
  bool _completed = false;

  LocalRecording? get _local => widget.local;

  String? get _serverId => widget.server?.id ?? _local?.serverId;

  String get _title =>
      _remote?.recording.title ?? widget.server?.title ?? _local?.title ?? '录音';

  @override
  void initState() {
    super.initState();
    _playerSubs.add(
      _player.positionStream.listen((value) {
        if (mounted) {
          setState(() => _position = value);
        }
      }),
    );
    _playerSubs.add(
      _player.durationStream.listen((value) {
        if (mounted && value != null) {
          setState(() => _duration = value);
        }
      }),
    );
    _playerSubs.add(
      _player.playerStateStream.listen((value) {
        if (mounted) {
          final completed = value.processingState == ProcessingState.completed;
          setState(() {
            _playing = value.playing && !completed;
            _completed = completed;
          });
        }
      }),
    );
    _bootstrap();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _waitServer?.cancel();
    _tabs.dispose();
    for (final sub in _playerSubs) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await Future.wait(<Future<void>>[_prepareAudio(), _loadRemote()]);
    // 刚停止的录音可能还在后台创建服务端记录：此时 serverId 还没写回本地账本。
    // 页面打开后等它出现，再拉一次详情，否则总结 tab 会一直停在“还没有上传”。
    if (mounted && _serverId == null && _local != null) {
      var attempts = 0;
      _waitServer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        attempts++;
        if (!mounted || attempts > 30) {
          timer.cancel();
          return;
        }
        if (_serverId == null) {
          return;
        }
        timer.cancel();
        await _loadRemote();
      });
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _prepareAudio() async {
    try {
      final local = _local;
      File? file;
      if (local != null) {
        final store = await ref.read(recordingStoreProvider.future);
        file = await store.ensurePlaybackFile(local);
      } else if (widget.server != null) {
        final api = ref.read(recordingApiProvider);
        if (api == null) {
          throw const ApiException(
            code: 'network_error',
            message: 'no api client',
            retryable: true,
            hint: '服务未连接，暂时无法播放服务端归档的音频',
          );
        }
        final support = await getApplicationSupportDirectory();
        final dir = Directory('${support.path}/recordings/_cache');
        await dir.create(recursive: true);
        final target = File('${dir.path}/${widget.server!.id}.wav');
        if (!await target.exists()) {
          final bytes = await api.audio(widget.server!.id);
          await target.writeAsBytes(bytes, flush: true);
        }
        file = target;
      }

      if (file == null) {
        throw const FileSystemException('没有可播放的音频');
      }
      await _player.setFilePath(file.path);
      _audioFile = file;
      if (mounted) {
        setState(() {
          _duration = _player.duration ?? Duration.zero;
        });
      }
      // 先出播放器（旧进度条），峰值算完再无缝换成波形：大文件扫描
      // 不该挡住首屏。
      unawaited(_loadPeaks(file));
    } on Object catch (error) {
      if (mounted) {
        setState(() => _loadError = _explain(error));
      }
    }
  }

  /// 在后台 isolate 里流式扫峰值。失败/超大/头不合法都只是保持 null，
  /// 界面继续用原进度条，不弹任何错误。
  Future<void> _loadPeaks(File file) async {
    final path = file.path;
    final peaks = await _scanPeaks(path);
    // 期间用户可能已经切到另一条录音：路径对不上就不写页面。
    if (!mounted || _audioFile?.path != path) {
      return;
    }
    setState(() => _peaks = peaks);
  }

  /// 扫峰值：优先放后台 isolate（大文件不卡 UI），isolate 这条路走不通时
  /// 退回当前 isolate 再算一遍——波形是锦上添花，但不该因为 isolate 的
  /// 环境差异整块消失。只在异常分支打一条日志，便于定位又不污染正常运行。
  Future<Uint8List?> _scanPeaks(String path) async {
    final Uint8List? peaks;
    try {
      peaks = await Isolate.run(() => peaksFromWavFile(path));
    } on Object catch (error) {
      debugPrint('波形峰值：后台 isolate 失败，改在主 isolate 重试（$error）');
      try {
        return await peaksFromWavFile(path);
      } on Object catch (retryError) {
        debugPrint('波形峰值：扫描失败，保留原进度条（$retryError）');
        return null;
      }
    }
    if (peaks == null) {
      debugPrint('波形峰值：文件头不可解析，保留原进度条（$path）');
    }
    return peaks;
  }

  Future<void> _loadRemote() async {
    final api = ref.read(recordingApiProvider);
    final id = _serverId;
    if (api == null || id == null) {
      return;
    }
    try {
      final detail = await api.detail(id);
      if (!mounted) {
        return;
      }
      setState(() => _remote = detail);
      _schedulePollIfNeeded(detail);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _actionError = error.userMessage);
      }
    }
  }

  bool _needsPolling(ServerRecordingDetail detail) =>
      detail.recording.status == RecordingStatus.transcribing ||
      detail.recording.status == RecordingStatus.recording ||
      detail.summary.status.isActive ||
      detail.summary.audioStatus.isActive;

  void _schedulePollIfNeeded(ServerRecordingDetail detail) {
    if (!_needsPolling(detail)) {
      return;
    }
    _poll?.cancel();
    var attempts = 0;
    _poll = Timer.periodic(const Duration(seconds: 2), (timer) async {
      attempts++;
      if (attempts > 90) {
        timer.cancel();
        return;
      }
      final api = ref.read(recordingApiProvider);
      final id = _serverId;
      if (api == null || id == null) {
        timer.cancel();
        return;
      }
      try {
        final next = await api.detail(id);
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _remote = next);
        if (!_needsPolling(next)) {
          timer.cancel();
          // 列表页此刻可能还在下面挂着：转写/总结刚结束就把它的快照打掉。
          ref.invalidate(recordingsLibraryProvider);
        }
      } on ApiException {
        // 轮询失败不弹错：下一轮还会继续，界面保留已有文本。
      }
    });
  }

  List<_Line> get _lines {
    final remote = _remote;
    if (remote != null) {
      return remote.segments
          .map(
            (segment) => _Line(
              seq: segment.seq,
              startMs: segment.startMs,
              endMs: segment.endMs,
              bytes: segment.bytes,
              text: segment.text,
              state: segment.state,
              error: segment.error,
            ),
          )
          .toList();
    }
    final local = _local;
    if (local == null) {
      return const <_Line>[];
    }
    return (List<LocalSegment>.from(local.segments)
          ..sort((a, b) => a.seq.compareTo(b.seq)))
        .map(
          (segment) => _Line(
            seq: segment.seq,
            startMs: segment.startMs,
            endMs: segment.endMs,
            bytes: segment.bytes,
            text: segment.text,
            state: segment.state,
            error: segment.error,
          ),
        )
        .toList();
  }

  /// 当前播放位置在**录制时间轴**上的毫秒数。
  ///
  /// 音频文件是把各分段 PCM 直接拼起来的紧凑 WAV，分段之间的静音没有保留；
  /// 因此播放器的 position 是"音频偏移"，转写稿与进度条用的是"录制时间"。
  int get _timelinePositionMs {
    if (_completed) {
      return _durationMs;
    }
    return _timeline.toTimeline(_position.inMilliseconds);
  }

  RecordingTimeline get _timeline => RecordingTimeline(
    _lines.map(
      (line) => RecordingTimelineSegment(
        startMs: line.startMs,
        endMs: line.endMs,
        bytes: line.bytes,
      ),
    ),
  );

  RecordingStatus get _status {
    final remote = _remote?.recording.status;
    if (remote != null) {
      return remote;
    }
    if (widget.server != null) {
      return widget.server!.status;
    }
    final local = _local;
    if (local == null) {
      return RecordingStatus.recorded;
    }
    if (local.serverId == null || !local.allUploaded) {
      return RecordingStatus.recorded;
    }
    final states = local.segments.map((segment) => segment.state).toList();
    if (states.any((state) => state == SegmentState.transcribing)) {
      return RecordingStatus.transcribing;
    }
    if (states.any((state) => state == SegmentState.stored)) {
      return RecordingStatus.recorded;
    }
    final ready = states.where((state) => state == SegmentState.ready).length;
    final failed = states.where((state) => state == SegmentState.failed).length;
    if (failed > 0 && ready > 0) {
      return RecordingStatus.partial;
    }
    if (failed > 0) {
      return RecordingStatus.failed;
    }
    return RecordingStatus.ready;
  }

  /// 正文要显示的行：上游明确"没有语音"的段会落成 ready + 空文本，
  /// 这种段只参与时间轴换算，不占正文位置。
  List<_Line> get _displayLines => _lines
      .where(
        (line) =>
            line.text.trim().isNotEmpty || line.state != SegmentState.ready,
      )
      .toList(growable: false);

  String get _transcript => _lines
      .where((line) => line.text.trim().isNotEmpty)
      .map((line) => line.text.trim())
      .join('\n');

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    // 原录音与总结语音互斥：开始一个时先停另一个。
    await _summaryPlayerKey.currentState?.pause();
    if (_completed) {
      // 播完后再点播放：从头开始，而不是停在末尾空转。
      await _player.seek(Duration.zero);
      if (mounted) {
        setState(() {
          _completed = false;
          _position = Duration.zero;
        });
      }
    }
    await _player.play();
  }

  /// 参数是**录制时间轴**上的毫秒数（转写稿时间戳、进度条位置）。
  /// 音频文件是去掉静音间隙的紧凑版本，要先映射成音频内的偏移再 seek。
  Future<void> _seekTo(int timelineMs) async {
    final audioMs = _timeline.toAudio(timelineMs);
    await _player.seek(Duration(milliseconds: audioMs));
    if (mounted) {
      setState(() {
        _completed = false;
        _position = Duration(milliseconds: audioMs);
      });
    }
  }

  /// 音频时间的播放比例 `0..1`。
  ///
  /// 波形画的是"音频时间轴"，不是录制时间轴：两者只差段间静音，
  /// 但用混了就会出现"波形走到底、标签还没到"的错位。
  double get _audioProgress {
    if (_completed) {
      return 1;
    }
    final total = _duration.inMilliseconds;
    if (total <= 0) {
      return 0;
    }
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// 点/拖波形：按音频比例 seek。进度标签由既有映射自动回算，不反过来改。
  Future<void> _seekToFraction(double fraction) async {
    final total = _duration.inMilliseconds;
    if (total <= 0) {
      return;
    }
    final audioMs = (fraction.clamp(0.0, 1.0) * total).round();
    await _player.seek(Duration(milliseconds: audioMs));
    if (mounted) {
      setState(() {
        _completed = false;
        _position = Duration(milliseconds: audioMs);
      });
    }
  }

  /// 总结语音开始播放时由播放器回调：暂停原录音。
  void _pauseOriginalForTts() {
    if (_playing) {
      unawaited(_player.pause());
    }
  }

  Future<void> _updateSummaryStyle(SummaryStyle style) async {
    final api = ref.read(recordingApiProvider);
    final id = _serverId;
    if (api == null || id == null) {
      _toast('服务未连接，暂时无法保存总结形式');
      return;
    }
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final detail = await api.updateSummaryStyle(id, style);
      if (!mounted) {
        return;
      }
      // 只保存选择：不重新生成、不清空现有总结与语音。
      setState(() => _remote = detail);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _actionError = error.userMessage);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _regenerateSummary(SummaryStyle style) async {
    final api = ref.read(recordingApiProvider);
    final id = _serverId;
    if (api == null || id == null) {
      _toast('服务未连接，暂时无法生成总结');
      return;
    }
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final detail = await api.regenerateSummary(id, style: style);
      if (!mounted) {
        return;
      }
      setState(() => _remote = detail);
      _schedulePollIfNeeded(detail);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _actionError = error.userMessage);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _ensureSummaryAudio() async {
    final api = ref.read(recordingApiProvider);
    final id = _serverId;
    if (api == null || id == null) {
      throw const ApiException(
        code: 'recording_unavailable',
        message: 'service unavailable',
        retryable: true,
        hint: '服务未连接，暂时无法生成语音',
      );
    }
    final detail = await api.ensureSummaryAudio(id);
    if (!mounted) {
      return;
    }
    setState(() => _remote = detail);
    _schedulePollIfNeeded(detail);
  }

  /// 从转写稿的某一句开始播放。
  ///
  /// 与进度条不同：点转写是"听这一段"，所以 seek 之后直接继续播放；
  /// 已经在播时只做跳转，不会把播放状态切成暂停。
  Future<void> _playFrom(int timelineMs) async {
    await _seekTo(timelineMs);
    if (!mounted) {
      return;
    }
    // `play()` 的 Future 要到暂停/播完才完成，这里不能 await，
    // 否则这一句会一直挂到录音结束。
    unawaited(_player.play());
  }

  Future<void> _copy() async {
    final transcript = _transcript;
    if (transcript.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: transcript));
    _toast('转写稿已复制');
  }

  Future<void> _exportMarkdown() async {
    final transcript = _transcript;
    if (transcript.isEmpty) {
      _toast('还没有转写内容可导出');
      return;
    }
    final buffer = StringBuffer()
      ..writeln('# ${_title.trim()}')
      ..writeln()
      ..writeln(
        '- 录制时间：${formatListTime(_local?.startedAt ?? widget.server?.createdAt ?? 0)}',
      )
      ..writeln('- 时长：${formatDuration(_durationMs)}')
      ..writeln('- 模式：${_mode.label}')
      ..writeln()
      ..writeln(transcript);
    await _export(
      '${_safeName(_title)}.md',
      utf8.encode(buffer.toString()),
      'text/markdown',
    );
  }

  Future<void> _exportWav() async {
    final file = _audioFile;
    if (file == null) {
      _toast('音频还没准备好');
      return;
    }
    await _export(
      '${_safeName(_title)}.wav',
      await file.readAsBytes(),
      'audio/wav',
    );
  }

  /// 把转写稿作为一条用户消息发到已有会话。
  ///
  /// 只发送、不跳转：用户可以在那边的会话里看模型的回应。
  /// 用 `client_msg_id` 去重，重复点不会产生两条一样的消息。
  Future<void> _sendToConversation() async {
    final transcript = _transcript;
    if (transcript.isEmpty) {
      _toast('还没有转写内容可发送');
      return;
    }
    final client = ref.read(apiClientProvider);
    if (client == null) {
      _toast('服务未连接，暂时无法发送');
      return;
    }

    setState(() => _busy = true);
    try {
      final page = await client.getJson(
        '/api/conversations',
        query: const <String, String>{'limit': '50'},
      );
      final items = (page['items'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(ConversationSummary.fromJson)
          .where((item) => item.id.isNotEmpty)
          .toList(growable: false);
      if (!mounted) {
        return;
      }
      if (items.isEmpty) {
        _toast('还没有会话，先在侧栏新建一个会话');
        return;
      }

      final chosen = await showDialog<ConversationSummary>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('发送到会话'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    formatListTime(item.updatedAt),
                    style: AppText.of(context).meta,
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(item),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (chosen == null) {
        return;
      }

      final message = '以下是一条录音的转写稿，请帮我整理要点：\n\n$transcript';
      final events = client.postSse(
        '/api/conversations/${chosen.id}/messages',
        <String, String>{
          'content': message,
          'client_msg_id': 'rec-${_serverId ?? _local?.clientId ?? 'local'}',
        },
      );
      // 只等这一轮结束，不消费正文：消息已经落库，用户去会话里看即可。
      await for (final event in events) {
        final type = event['type'];
        if (type == 'message_completed' || type == 'error') {
          break;
        }
      }
      _toast('已发送到「${chosen.title}」');
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _actionError = error.userMessage);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _export(String name, List<int> bytes, String mime) async {
    final exporter = ref.read(artifactExporterProvider);
    final result = await exporter.export(
      suggestedName: name,
      bytes: bytes,
      mime: mime,
      shareOrigin: _shareOrigin(),
    );
    if (result.outcome == ExportOutcome.saved) {
      _toast('已保存到 ${result.path ?? name}');
    }
  }

  Rect? _shareOrigin() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _title);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 200,
          decoration: const InputDecoration(hintText: '给这条录音起个名字'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) {
      return;
    }

    final local = _local;
    if (local != null) {
      await ref
          .read(recordingControllerProvider.notifier)
          .rename(local, result);
    } else {
      final api = ref.read(recordingApiProvider);
      final id = _serverId;
      if (api != null && id != null) {
        await api.rename(id, result.trim());
      }
    }
    await _loadRemote();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _retry() async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final local = _local;
      if (local != null) {
        await ref.read(recordingControllerProvider.notifier).retry(local);
      } else {
        final api = ref.read(recordingApiProvider);
        final id = _serverId;
        if (api != null && id != null) {
          await api.retry(id);
        }
      }
      await _loadRemote();
      ref.invalidate(recordingsLibraryProvider);
    } on ApiException catch (error) {
      setState(() => _actionError = error.userMessage);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条录音？'),
        content: const Text('本地音频与服务端归档会一起删除，无法恢复。转写稿也会一并清掉。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.of(dialogContext).status.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    setState(() => _busy = true);
    final local = _local;
    if (local != null) {
      await ref.read(recordingControllerProvider.notifier).delete(local);
    } else {
      final api = ref.read(recordingApiProvider);
      final id = _serverId;
      if (api != null && id != null) {
        await api.delete(id);
      }
    }
    ref.invalidate(recordingsLibraryProvider);
    if (!mounted) {
      return;
    }
    // 内嵌形态没有路由可退：交给外壳切回列表并从历史里剪掉这一页。
    final onDeleted = widget.onDeleted;
    if (onDeleted != null) {
      onDeleted();
      return;
    }
    Navigator.of(context).pop();
  }



  int get _durationMs {
    final remote = _remote?.recording.durationMs;
    if (remote != null && remote > 0) {
      return remote;
    }
    final local = _local?.durationMs;
    if (local != null && local > 0) {
      return local;
    }
    final fromPlayer = _duration.inMilliseconds;
    return fromPlayer > 0 ? fromPlayer : widget.server?.durationMs ?? 0;
  }

  RecordingMode get _mode =>
      _remote?.recording.mode ??
      _local?.mode ??
      widget.server?.mode ??
      RecordingMode.batch;

  int get _bytes =>
      _remote?.recording.bytes ?? _local?.bytes ?? widget.server?.bytes ?? 0;

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final status = _status;
    final color = _statusColor(status, palette);

    // 「更多」的浮层：整页与内嵌共用，只有触发器换——内嵌是栏头 IconButton，
    // 窄屏是胶囊里的一格（见下方 actions）。
    final moreMenu = AgentMenu<String>(
      width: kRecordingMenuWidth,
      // 窄屏时 tooltip 由圆钮自己给：两层都挂会连续弹两次。
      tooltip: widget.embedded ? '更多' : null,
      alignment: AlignmentDirectional.bottomEnd,
      alignmentOffset: AgentMenuStyle.rightAlignedOffset(
        kRecordingMenuWidth,
      ),
      // 触发器是自带 onPressed 的 IconButton：点击交给它，
      // 组件只负责开合与浮层定位。
      triggerHandlesTap: false,
      groups: <AgentMenuGroup<String>>[
        AgentMenuGroup<String>(
          items: <AgentMenuItem<String>>[
            AgentMenuItem<String>(
              value: 'copy',
              label: '复制全文',
              icon: Icons.copy_all_outlined,
              enabled: !_busy,
            ),
            AgentMenuItem<String>(
              value: 'send',
              label: '发送到会话',
              icon: Icons.forum_outlined,
              enabled: !_busy,
            ),
            AgentMenuItem<String>(
              value: 'markdown',
              label: '导出 Markdown',
              icon: Icons.description_outlined,
              enabled: !_busy,
            ),
            AgentMenuItem<String>(
              value: 'wav',
              label: '导出 WAV',
              icon: Icons.audio_file_outlined,
              enabled: !_busy,
            ),
            if (_serverId != null)
              AgentMenuItem<String>(
                value: 'retry',
                label: '重新转写',
                icon: Icons.refresh,
                enabled: !_busy,
              ),
            AgentMenuItem<String>(
              value: 'delete',
              label: '删除录音',
              icon: Icons.delete_outline,
              dividerBefore: true,
              enabled: !_busy,
            ),
          ],
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'copy':
            _copy();
          case 'send':
            _sendToConversation();
          case 'retry':
            _retry();
          case 'markdown':
            _exportMarkdown();
          case 'wav':
            _exportWav();
          case 'delete':
            _delete();
        }
      },
      builder: (context, controller, open, hovering) {
        void toggle() => controller.isOpen
            ? controller.close()
            : controller.open();
        if (!widget.embedded) {
          // 窄屏：「更多」和「重命名」同处一枚胶囊，背板由整组画一次。
          return MobileTopBarButton(
            bare: true,
            glyph: MobileTopBarGlyph.more,
            tooltip: '更多',
            onPressed: _busy ? null : toggle,
          );
        }
        return IconButton(
          onPressed: _busy ? null : toggle,
          style: _headerButtonStyle,
          iconSize: kPaneHeaderIconSize,
          icon: const Icon(Icons.more_horiz),
        );
      },
    );

    // 整页与内嵌共用同一份动作：内嵌时按钮尺寸收到栏头那一档，窄屏整页把
    // 「重命名 + 更多」并成一枚 38dp 玻璃胶囊。
    final actions = <Widget>[
      if (widget.embedded) ...<Widget>[
        IconButton(
          tooltip: '重命名',
          onPressed: _busy ? null : _rename,
          style: _headerButtonStyle,
          iconSize: kPaneHeaderIconSize,
          icon: const Icon(Icons.edit_outlined),
        ),
        moreMenu,
      ] else
        MobileTopBarButtonGroup(
          children: <Widget>[
            MobileTopBarButton(
              bare: true,
              icon: Icons.edit_outlined,
              tooltip: '重命名',
              onPressed: _busy ? null : _rename,
            ),
            moreMenu,
          ],
        ),
    ];

    return AppPageScaffold(
      // 与中栏其他页面同一层栏底：内嵌时底色由骨架的渐变透上来；
      // 窄屏整页由 AppPageScaffold 铺整窗渐变。
      backgroundColor: widget.embedded
          ? paneSurfaceColor(Theme.of(context).colorScheme)
          : null,
      // 内嵌形态不画第二层 AppBar：外层已经是三栏统一的细栏头。
      appBar: widget.embedded
          ? null
          : MobileAppBar(title: _title, actions: actions),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.embedded)
              EmbeddedToolbar(title: _title, actions: actions),
            Expanded(
              child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_actionError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Text(
                      _actionError!,
                      style: text.hint.copyWith(color: palette.status.danger),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: TabBar(
                    controller: _tabs,
                    labelColor: palette.text.primary,
                    unselectedLabelColor: palette.text.secondary,
                    indicatorColor: Theme.of(context).colorScheme.primary,
                    dividerColor: Theme.of(context).colorScheme.outlineVariant,
                    indicatorSize: TabBarIndicatorSize.label,
                    labelStyle: text.row.copyWith(fontWeight: AppWeight.medium),
                    unselectedLabelStyle: text.row,
                    tabs: const <Widget>[
                      Tab(text: '实时内容'),
                      Tab(text: '总结'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: <Widget>[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                            child: _PlayerCard(
                              status: status,
                              statusColor: color,
                              mode: _mode,
                              durationMs: _durationMs,
                              bytes: _bytes,
                              position: Duration(
                                milliseconds: _timelinePositionMs,
                              ),
                              playing: _playing,
                              speed: _speed,
                              loading: _loading,
                              error: _loadError,
                              peaks: _peaks,
                              audioProgress: _audioProgress,
                              audioDuration: _duration,
                              onSeekFraction: _seekToFraction,
                              onToggle: _togglePlay,
                              onSeek: _seekTo,
                              onSpeed: (value) async {
                                await _player.setSpeed(value);
                                if (mounted) {
                                  setState(() => _speed = value);
                                }
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    _transcript.isEmpty
                                        ? (status ==
                                                  RecordingStatus.transcribing
                                              ? '正在转写…'
                                              : '还没有文字')
                                        : '${_displayLines.length} 段',
                                    style: text.meta,
                                  ),
                                ),
                                if (_status == RecordingStatus.partial ||
                                    _status == RecordingStatus.failed)
                                  TextButton.icon(
                                    onPressed: _busy ? null : _retry,
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text('重试失败段'),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(child: _buildTranscript(text, palette)),
                        ],
                      ),
                      RecordingSummaryTab(
                        serverId: _serverId,
                        recordingStatus: status,
                        summary: _remote?.summary ?? const RecordingSummary(),
                        summaryAvailable:
                            ref
                                .watch(recordingInfoProvider)
                                .value
                                ?.summaryAvailable ==
                            true,
                        ttsAvailable:
                            ref
                                .watch(recordingInfoProvider)
                                .value
                                ?.ttsAvailable ==
                            true,
                        playerKey: _summaryPlayerKey,
                        onWillPlayTts: _pauseOriginalForTts,
                        onEnsureAudio: _ensureSummaryAudio,
                        onStyleSelected: _updateSummaryStyle,
                        onRegenerate: _regenerateSummary,
                        busy: _busy,
                        actionError: _actionError,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscript(AppText text, AppPalette palette) {
    final lines = _displayLines;
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _status == RecordingStatus.transcribing
                ? '服务端正在逐段转写，通常几秒到一两分钟。'
                : '这段录音没有可显示的文字。',
            textAlign: TextAlign.center,
            style: text.hint,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 20, 24),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        final positionMs = _timelinePositionMs;
        final active = positionMs >= line.startMs && positionMs < line.endMs;
        return _TranscriptRow(
          line: line,
          active: active,
          hasAudio: _audioFile != null,
          onSeek: () => _playFrom(line.startMs),
        );
      },
    );
  }

  Color _statusColor(RecordingStatus status, AppPalette palette) =>
      recordingStatusColor(status, palette);

  String _safeName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return cleaned.isEmpty ? 'recording' : cleaned;
  }

  String _explain(Object error) {
    if (error is ApiException) {
      return error.userMessage;
    }
    if (error is FileSystemException) {
      return '音频文件不完整：${error.message}';
    }
    return '无法加载音频：$error';
  }
}

class _Line {
  const _Line({
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

  /// 分段 WAV 的字节数（含 44 字节头）。播放文件去掉了段间静音，
  /// 用它反推这段音频的实际时长，才能把播放进度映射回录制时间轴。
  final int bytes;
  final String text;
  final SegmentState state;
  final String? error;
}

class _PlayerCard extends StatelessWidget {
  const _PlayerCard({
    required this.status,
    required this.statusColor,
    required this.mode,
    required this.durationMs,
    required this.bytes,
    required this.position,
    required this.playing,
    required this.speed,
    required this.loading,
    required this.error,
    required this.peaks,
    required this.audioProgress,
    required this.audioDuration,
    required this.onSeekFraction,
    required this.onToggle,
    required this.onSeek,
    required this.onSpeed,
  });

  final RecordingStatus status;
  final Color statusColor;
  final RecordingMode mode;
  final int durationMs;
  final int bytes;
  final Duration position;
  final bool playing;
  final double speed;
  final bool loading;
  final String? error;

  /// null 表示峰值还没算好或不可用：退回原进度条。
  final Uint8List? peaks;

  /// 音频时间的播放比例（不是录制时间轴）。
  final double audioProgress;

  /// 音频真实时长，供波形的读屏 ±5 秒步进换算。
  final Duration audioDuration;
  final ValueChanged<double> onSeekFraction;
  final VoidCallback onToggle;
  final ValueChanged<int> onSeek;
  final ValueChanged<double> onSpeed;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final maxMs = durationMs > 0 ? durationMs : 1;
    final value = position.inMilliseconds.clamp(0, maxMs).toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              RecordingStatusChip(label: status.label, color: statusColor),
              const SizedBox(width: 8),
              Text(mode.label, style: text.meta),
              const Spacer(),
              Text(
                '${formatBytes(bytes)} · ${formatDuration(durationMs)}',
                style: text.meta,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              IconButton.filled(
                tooltip: playing ? '暂停' : '播放',
                onPressed: loading || error != null ? null : onToggle,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: peaks == null
                    // 峰值未就绪：保持原进度条，不阻塞首屏也不改变手感。
                    ? Slider(
                        value: value,
                        max: maxMs.toDouble(),
                        onChanged: loading || error != null
                            ? null
                            : (next) => onSeek(next.round()),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: WaveformTimeline(
                          peaks: peaks,
                          progress: audioProgress,
                          color: Theme.of(context).colorScheme.primary,
                          duration: audioDuration,
                          onSeek: loading || error != null
                              ? null
                              : onSeekFraction,
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              AgentMenu<double>(
                width: _kSpeedMenuWidth,
                tooltip: '倍速',
                alignment: AlignmentDirectional.bottomEnd,
                alignmentOffset: AgentMenuStyle.rightAlignedOffset(
                  _kSpeedMenuWidth,
                ),
                triggerHandlesTap: false,
                groups: <AgentMenuGroup<double>>[
                  AgentMenuGroup<double>(
                    items: <AgentMenuItem<double>>[
                      for (final value in const <double>[1, 1.5, 2])
                        AgentMenuItem<double>(
                          value: value,
                          label: '${value.toStringAsFixed(1)}×',
                          selected: speed == value,
                        ),
                    ],
                  ),
                ],
                onSelected: onSpeed,
                builder: (context, controller, open, hovering) => InkWell(
                  onTap: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      '${speed.toStringAsFixed(1)}×',
                      style: text.mono(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Text(formatDuration(position.inMilliseconds), style: text.meta),
              const Spacer(),
              Text(formatDuration(durationMs), style: text.meta),
            ],
          ),
          if (error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              error!,
              style: text.hint.copyWith(color: palette.status.danger),
            ),
          ],
        ],
      ),
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({
    required this.line,
    required this.active,
    required this.hasAudio,
    required this.onSeek,
  });

  final _Line line;
  final bool active;
  final bool hasAudio;
  final VoidCallback onSeek;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    final failed = line.state == SegmentState.failed;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? palette.status.surfaceOf(palette.accent.projectStart)
            : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      // 整行都可点，而不是只有左边的时间戳能点：
      // 用户想"从这句开始听"时，视线和鼠标通常落在正文上。
      child: InkWell(
        onTap: hasAudio ? onSeek : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 66,
              child: TextButton(
                onPressed: hasAudio ? onSeek : null,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 32),
                  alignment: Alignment.topLeft,
                ),
                child: Text(
                  formatSegmentStamp(line.startMs),
                  style: text.meta.copyWith(
                    color: active ? palette.accent.projectStart : null,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      line.text.trim().isEmpty
                          ? (failed ? '这一段没转出来' : '（这一段没有语音）')
                          : line.text.trim(),
                      style: text.bodyTight.copyWith(
                        color: failed
                            ? palette.status.danger
                            : line.text.trim().isEmpty
                            ? palette.text.tertiary
                            : null,
                      ),
                    ),
                    if (line.error != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        line.error!,
                        style: text.hint.copyWith(color: palette.status.danger),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
