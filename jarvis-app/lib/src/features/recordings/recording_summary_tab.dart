import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_error.dart';
import '../../core/design/app_palette.dart';
import '../../core/design/app_text_styles.dart';
import '../../core/design/app_tokens.dart';
import '../../core/recording/recording_formatters.dart';
import '../../core/recording/recording_models.dart';
import '../../core/recording/recording_providers.dart';
import '../../core/ui/agent_menu.dart';
import '../conversations/message_markdown.dart';
import 'waveform_timeline.dart';

/// 详情页的「总结」tab：状态、会议纪要正文与总结语音播放器。
class RecordingSummaryTab extends StatelessWidget {
  const RecordingSummaryTab({
    super.key,
    required this.serverId,
    required this.recordingStatus,
    required this.summary,
    required this.summaryAvailable,
    required this.ttsAvailable,
    required this.playerKey,
    required this.onWillPlayTts,
    required this.onEnsureAudio,
    required this.onStyleSelected,
    required this.onRegenerate,
    this.busy = false,
    this.actionError,
  });

  final String? serverId;
  final RecordingStatus recordingStatus;
  final RecordingSummary summary;
  final bool summaryAvailable;
  final bool ttsAvailable;
  final GlobalKey<RecordingSummaryPlayerState> playerKey;
  final VoidCallback onWillPlayTts;
  final Future<void> Function() onEnsureAudio;
  final Future<void> Function(SummaryStyle style) onStyleSelected;
  final Future<void> Function(SummaryStyle style) onRegenerate;
  final bool busy;
  final String? actionError;

  SummaryStyle get _preference => summary.stylePreference;

  bool get _selectionPending =>
      summary.isReady &&
      summary.style != null &&
      summary.style != summary.stylePreference;

  bool get _canGenerate =>
      recordingStatus == RecordingStatus.ready ||
      recordingStatus == RecordingStatus.partial;

  String get _waitingTitle {
    if (!summaryAvailable) {
      return '服务端未开启总结';
    }
    if (_canGenerate) {
      return '还没有总结';
    }
    return '等待转写完成';
  }

  String get _waitingBody {
    if (!summaryAvailable) {
      return '录音与转写仍可正常使用；配置模型后可生成总结。';
    }
    if (_canGenerate) {
      return '可以点下方按钮生成总结，之后会自动保存。';
    }
    return '全部分段转写完成后会自动生成总结。';
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);

    if (serverId == null) {
      return _CenteredHint(
        title: '这条录音还没有上传',
        body: '开启上传并连接服务端后，转写完成会自动生成总结。',
        style: text,
      );
    }

    if (!summaryAvailable && !summary.isReady && !summary.status.isActive) {
      return _CenteredHint(
        title: '服务端未开启总结',
        body: '录音与转写仍可正常使用；配置模型后可生成总结。',
        style: text,
      );
    }

    final locked = busy || summary.status.isActive;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('总结', style: text.cardTitle),
              const Spacer(),
              if (summaryAvailable)
                _StyleMenu(
                  selected: _preference,
                  enabled: !locked,
                  onSelected: onStyleSelected,
                ),
            ],
          ),
          if (_selectionPending) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '已选择「${_preference.label}」，点击重新生成后生效。',
              style: text.hint.copyWith(color: palette.accent.projectStart),
            ),
          ],
          if (actionError != null) ...<Widget>[
            const SizedBox(height: 12),
            _ErrorBanner(message: actionError!),
          ],
          const SizedBox(height: 12),
          if (summary.isReady) ...<Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 16,
                        color: palette.accent.projectStart,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        summary.style?.label ?? _preference.label,
                        style: text.row.copyWith(fontWeight: AppWeight.medium),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  MessageMarkdown(data: summary.text),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: busy ? null : () => onRegenerate(_preference),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text('按${_preference.label}重新生成'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (ttsAvailable)
              RecordingSummaryPlayer(
                key: playerKey,
                recordingId: serverId!,
                summary: summary,
                onWillPlay: onWillPlayTts,
                onEnsureAudio: onEnsureAudio,
              )
            else
              _CenteredHint(
                title: '服务端未开启语音合成',
                body: '总结文字仍可查看；开启 TTS 后可在这里朗读。',
                style: text,
              ),
          ] else if (summary.status == SummaryStatus.failed) ...<Widget>[
            _CenteredHint(
              title: '总结生成失败',
              body: summary.error ?? '可以重新生成一次',
              style: text,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : () => onRegenerate(_preference),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text('按${_preference.label}重新生成'),
            ),
          ] else if (summary.status.isActive) ...<Widget>[
            const SizedBox(height: 44),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Text(
              '正在整理转写稿，通常几秒到半分钟。',
              textAlign: TextAlign.center,
              style: text.hint,
            ),
          ] else ...<Widget>[
            _CenteredHint(
              title: _waitingTitle,
              body: _waitingBody,
              style: text,
            ),
            if (summaryAvailable && _canGenerate)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: FilledButton.icon(
                  onPressed: busy ? null : () => onRegenerate(_preference),
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text('按${_preference.label}生成总结'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CenteredHint extends StatelessWidget {
  const _CenteredHint({
    required this.title,
    required this.body,
    required this.style,
  });

  final String title;
  final String body;
  final AppText style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Column(
        children: <Widget>[
          Text(title, textAlign: TextAlign.center, style: style.section),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: style.hint),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = AppText.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: palette.status.surfaceOf(palette.status.danger),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: palette.status.borderOf(palette.status.danger),
        ),
      ),
      child: Text(message, style: text.hint),
    );
  }
}

class _StyleMenu extends StatelessWidget {
  const _StyleMenu({
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final SummaryStyle selected;
  final bool enabled;
  final Future<void> Function(SummaryStyle style) onSelected;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return AgentMenu<SummaryStyle>(
      width: 248,
      tooltip: '选择总结形式',
      alignment: AlignmentDirectional.bottomEnd,
      alignmentOffset: AgentMenuStyle.rightAlignedOffset(248),
      triggerHandlesTap: false,
      groups: <AgentMenuGroup<SummaryStyle>>[
        AgentMenuGroup<SummaryStyle>(
          items: <AgentMenuItem<SummaryStyle>>[
            for (final style in SummaryStyle.values)
              AgentMenuItem<SummaryStyle>(
                value: style,
                label: style.label,
                subtitle: style.hint,
                selected: style == selected,
                enabled: enabled,
              ),
          ],
        ),
      ],
      onSelected: (style) => unawaited(onSelected(style)),
      builder: (context, controller, open, hovering) => InkWell(
        onTap: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.tune,
                size: 16,
                color: enabled
                    ? AppPalette.of(context).text.secondary
                    : AppPalette.of(context).text.disabled,
              ),
              const SizedBox(width: 4),
              Text(
                selected.label,
                style: text.row.copyWith(
                  color: enabled
                      ? AppPalette.of(context).text.primary
                      : AppPalette.of(context).text.disabled,
                ),
              ),
              AgentMenuChevron(open: open, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// 总结语音播放器。
///
/// 首次点播放时由服务端按需合成；这里在父级轮询到 `audio_status=ready`
/// 后下载到临时文件再播放，避免把鉴权头与自签证书直接交给播放器。
class RecordingSummaryPlayer extends ConsumerStatefulWidget {
  const RecordingSummaryPlayer({
    super.key,
    required this.recordingId,
    required this.summary,
    required this.onWillPlay,
    required this.onEnsureAudio,
  });

  final String recordingId;
  final RecordingSummary summary;
  final VoidCallback onWillPlay;
  final Future<void> Function() onEnsureAudio;

  @override
  ConsumerState<RecordingSummaryPlayer> createState() =>
      RecordingSummaryPlayerState();
}

class RecordingSummaryPlayerState
    extends ConsumerState<RecordingSummaryPlayer> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  /// 播放到结尾。`position` 会停在末尾，此时直接 `play()` 是"末尾空转"，
  /// 用户的感受就是"播过一次就点不动了"——与原录音播放器的 `_completed` 同理。
  bool _completed = false;
  bool _loading = false;
  bool _pendingPlay = false;
  double _speed = 1;
  String? _error;
  int? _loadedVersion;

  /// 波形峰值。null 表示还没拉到或接口不可用，此时保留原进度条。
  Uint8List? _peaks;

  /// 已经成功缓存峰值的语音版本：重生成后版本变化，自然重取。
  int? _peaksVersion;

  /// 正在请求峰值的版本：同一版本只发一次，避免重建时重复请求。
  int? _peaksLoading;

  @override
  void initState() {
    super.initState();
    _subs.add(
      _player.positionStream.listen((value) {
        if (mounted) {
          setState(() => _position = value);
        }
      }),
    );
    _subs.add(
      _player.durationStream.listen((value) {
        if (mounted && value != null) {
          setState(() => _duration = value);
        }
      }),
    );
    _subs.add(
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
    // 语音已经生成过：进总结页就把峰值拉回来，不等点播放。
    _maybeLoadPeaks();
  }

  @override
  void didUpdateWidget(covariant RecordingSummaryPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary.audioUpdatedAt != widget.summary.audioUpdatedAt) {
      _loadedVersion = null;
      _peaks = null;
      _peaksVersion = null;
      _peaksLoading = null;
      _error = null;
      unawaited(_player.pause());
      _player.seek(Duration.zero);
      _position = Duration.zero;
      _duration = Duration.zero;
      _completed = false;
    }
    if (_pendingPlay &&
        widget.summary.audioStatus == SummaryAudioStatus.ready) {
      unawaited(_loadAndPlay());
    } else if (_pendingPlay &&
        widget.summary.audioStatus == SummaryAudioStatus.failed) {
      _pendingPlay = false;
      _loading = false;
      _error = widget.summary.audioError ?? '语音合成失败';
    }
    // 合成中 → 合成完成的这一次重建，要主动把波形补上。
    _maybeLoadPeaks();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  /// 原录音开始播放时由父级调用。
  Future<void> pause() async {
    if (_playing || _player.processingState != ProcessingState.idle) {
      await _player.pause();
    }
  }

  Future<void> _toggle() async {
    if (_loading) {
      return;
    }
    if (_playing) {
      await _player.pause();
      return;
    }
    widget.onWillPlay();
    if (widget.summary.audioStatus == SummaryAudioStatus.ready &&
        widget.summary.audioUpdatedAt != null) {
      await _loadAndPlay();
      return;
    }
    setState(() {
      _pendingPlay = true;
      _loading = true;
      _error = null;
    });
    try {
      await widget.onEnsureAudio();
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _pendingPlay = false;
          _loading = false;
          _error = error.userMessage;
        });
      }
    }
    // 父级拿到新的 audio_status 后会通过 didUpdateWidget 触发加载。
    if (mounted && widget.summary.audioStatus != SummaryAudioStatus.ready) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadAndPlay() async {
    final version = widget.summary.audioUpdatedAt;
    if (version == null) {
      return;
    }
    if (_loadedVersion == version) {
      widget.onWillPlay();
      await _restartIfCompleted();
      if (!mounted) {
        return;
      }
      unawaited(_player.play());
      unawaited(_loadPeaks(version));
      return;
    }
    // 详情页轮询和按钮点击可能在同一帧各触发一次加载：只允许一个下载/写文件。
    if (_loading) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = await getTemporaryDirectory();
      if (!mounted) {
        return;
      }
      // 沙盒里的 Caches 目录可能还没被创建；不先建目录，writeAsBytes 会
      // 抛 PathNotFoundException，看起来像"音频文件丢了"。
      await dir.create(recursive: true);
      if (!mounted) {
        return;
      }
      final format = widget.summary.audioFormat ?? 'mp3';
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'recording_summary_${widget.recordingId}_$version.$format',
      );
      // 之前失败可能留下 0 字节文件：只判断 exists 会一直拿坏文件去播放。
      final cached = await file.exists() && await file.length() > 0;
      if (!cached) {
        if (await file.exists()) {
          await file.delete();
        }
        final api = ref.read(recordingApiProvider);
        if (api == null) {
          throw const ApiException(
            code: 'recording_unavailable',
            message: '服务未连接',
            retryable: true,
            hint: '服务未连接，暂时无法播放总结语音',
          );
        }
        final bytes = await api.summaryAudio(widget.recordingId);
        if (!mounted) {
          return;
        }
        await file.writeAsBytes(bytes, flush: true);
      }
      if (!mounted) {
        return;
      }
      await _player.setFilePath(file.path);
      await _player.setSpeed(_speed);
      _loadedVersion = version;
      unawaited(_loadPeaks(version));
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _pendingPlay = false;
      });
      widget.onWillPlay();
      unawaited(_player.play());
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _pendingPlay = false;
          _error = error.userMessage;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _pendingPlay = false;
          _error = '播放语音失败：$error';
        });
      }
    }
  }

  /// 语音已经就绪就先拉峰值，不等用户点播放。
  ///
  /// 未生成、合成中都按兵不动：那会儿接口也是 409，没必要打。
  void _maybeLoadPeaks() {
    final version = widget.summary.audioUpdatedAt;
    if (version == null) {
      return;
    }
    if (widget.summary.audioStatus != SummaryAudioStatus.ready) {
      return;
    }
    unawaited(_loadPeaks(version));
  }

  /// 按语音版本拉一次峰值。
  ///
  /// 任何失败（服务端没开 TTS、解码失败、离线）都只是保持 null，
  /// 播放器继续用原进度条：波形是锦上添花，不能阻断播放。
  /// 失败不写 `_peaksVersion`，下次点播放会再试一次。
  Future<void> _loadPeaks(int version) async {
    if (_peaksVersion == version || _peaksLoading == version) {
      return;
    }
    final api = ref.read(recordingApiProvider);
    if (api == null) {
      return;
    }
    _peaksLoading = version;
    try {
      SummaryAudioPeaks? result;
      try {
        result = await api.summaryAudioPeaks(widget.recordingId);
      } on Object {
        result = null;
      }
      if (!mounted) {
        return;
      }
      // 期间语音被重生成：这一份已经过期，等下一次触发。
      if (widget.summary.audioUpdatedAt != version) {
        return;
      }
      // 接口失败或版本对不上：不记版本，下次点播放还能再试一次。
      if (result == null) {
        return;
      }
      if (result.version != null && result.version != version) {
        return;
      }
      if (!result.isUsable) {
        // 服务端确实没有峰值（空数组）：别在每次重建时反复问。
        _peaksVersion = version;
        return;
      }
      final peaks = result.peaks;
      setState(() {
        _peaks = peaks;
        _peaksVersion = version;
      });
    } finally {
      if (_peaksLoading == version) {
        _peaksLoading = null;
      }
    }
  }

  /// 播完后再点播放：先回到开头。
  ///
  /// 不这么做的话 `play()` 会从 `position == duration` 处继续，
  /// 立刻又变回 completed，表现成"播放键按了没反应"。
  Future<void> _restartIfCompleted() async {
    if (!_completed) {
      return;
    }
    await _player.seek(Duration.zero);
    if (mounted) {
      setState(() {
        _completed = false;
        _position = Duration.zero;
      });
    }
  }

  Future<void> _seekTo(int milliseconds) async {
    await _player.seek(Duration(milliseconds: milliseconds));
    // 播完后拖动进度条：相当于取消了"已播完"状态，
    // 下一次点播放应该从这里继续，而不是被拉回开头。
    if (mounted && _completed) {
      setState(() => _completed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final palette = AppPalette.of(context);
    final maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds : 1;
    final value = _position.inMilliseconds.clamp(0, maxMs).toDouble();
    final active = widget.summary.audioStatus.isActive;
    // 合成中或正在下载时，按钮不再显示"可播放"的三角：禁用并换成转圈，
    // 避免用户反复点击导致重复 ensure。
    final waiting = _loading || active;
    final errorText = _error ?? widget.summary.audioError;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.record_voice_over_outlined,
                size: 16,
                color: palette.accent.projectStart,
              ),
              const SizedBox(width: 8),
              Text('语音摘要', style: text.row),
              const Spacer(),
              Text(
                widget.summary.audioTruncated ? '节选' : 'AI 语音',
                style: text.meta,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              IconButton.filled(
                tooltip: active
                    ? '正在生成语音'
                    : _loading
                    ? '正在准备语音'
                    : _playing
                    ? '暂停'
                    : '播放',
                onPressed: waiting ? null : _toggle,
                icon: waiting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.text.secondary,
                        ),
                      )
                    : Icon(_playing ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _peaks == null
                    ? Slider(
                        value: value,
                        max: maxMs.toDouble(),
                        onChanged: waiting || _duration.inMilliseconds <= 0
                            ? null
                            : (next) => _seekTo(next.round()),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: WaveformTimeline(
                          peaks: _peaks,
                          progress: _duration.inMilliseconds > 0
                              ? _position.inMilliseconds /
                                    _duration.inMilliseconds
                              : 0,
                          color: Theme.of(context).colorScheme.primary,
                          // TTS 卡片比详情页窄，波形矮一档。
                          height: 36,
                          duration: _duration,
                          onSeek: waiting || _duration.inMilliseconds <= 0
                              ? null
                              : (fraction) => _seekTo(
                                  (fraction * _duration.inMilliseconds).round(),
                                ),
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              AgentMenu<double>(
                width: 120,
                tooltip: '倍速',
                alignment: AlignmentDirectional.bottomEnd,
                alignmentOffset: AgentMenuStyle.rightAlignedOffset(120),
                triggerHandlesTap: false,
                groups: <AgentMenuGroup<double>>[
                  AgentMenuGroup<double>(
                    items: <AgentMenuItem<double>>[
                      for (final value in const <double>[1, 1.5, 2])
                        AgentMenuItem<double>(
                          value: value,
                          label: '${value.toStringAsFixed(1)}×',
                          selected: _speed == value,
                          enabled: !waiting,
                        ),
                    ],
                  ),
                ],
                onSelected: (value) async {
                  await _player.setSpeed(value);
                  if (mounted) {
                    setState(() => _speed = value);
                  }
                },
                builder: (context, controller, open, hovering) => InkWell(
                  onTap: waiting
                      ? null
                      : () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      '${_speed.toStringAsFixed(1)}×',
                      style: text.mono().copyWith(
                        color: waiting
                            ? palette.text.disabled
                            : palette.text.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Text(formatDuration(_position.inMilliseconds), style: text.meta),
              const Spacer(),
              Text(formatDuration(_duration.inMilliseconds), style: text.meta),
            ],
          ),
          if (waiting) ...<Widget>[
            const SizedBox(height: 8),
            Text(active ? '正在生成语音…' : '正在准备语音…', style: text.hint),
          ],
          if (errorText != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              errorText,
              style: text.hint.copyWith(color: palette.status.danger),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: waiting ? null : _toggle,
                child: const Text('重新生成语音'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
