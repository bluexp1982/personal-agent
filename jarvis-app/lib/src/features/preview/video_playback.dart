import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频播放内核的抽象。
///
/// 为什么要有这一层：`media_kit` 的 `Player` 一构造就碰原生库（libmpv），
/// widget 测试里跑不起来。查看器只依赖这个接口，测试用纯 Dart 假实现替换，
/// 于是"控件长什么样、全屏回调有没有触发、拖动进度有没有 seek"都能在测试里验证，
/// 而真正播不播得动由手工验收。
///
/// 只暴露查看器需要的东西：宿主（右栏标签 / 全屏路由）决定布局与全屏，
/// 这里不判断自己是不是全屏。
abstract class VideoPlayback extends ChangeNotifier {
  /// 是否正在播放。
  bool get playing;

  /// 是否卡在缓冲（网络源才有意义，本地文件一般只在起播瞬间为真）。
  bool get buffering;

  /// 是否已经拿到时长。为真之前控件显示转圈而不是 0:00 / 0:00。
  bool get ready;

  /// 播放结束。
  bool get completed;

  Duration get position;
  Duration get duration;

  /// 0–1。
  double get volume;

  /// 播放倍速，1 为正常速度。
  double get speed;

  /// 解码失败原因。非空时画面区域改画错误提示。
  String? get error;

  /// 换片源。同一个实例复用：查看器里换文件才需要重开，面板里基本用不上。
  Future<void> open(File file);

  Future<void> play();
  Future<void> pause();
  Future<void> toggle();

  Future<void> seek(Duration position);

  /// 0–1。
  Future<void> setVolume(double volume);

  Future<void> setSpeed(double speed);

  /// 画面。真实实现返回 `media_kit_video` 的 `Video`（自带纹理渲染），
  /// 假实现返回一个占位块。
  Widget buildSurface();
}

/// 播放 / 暂停共用的那一下切换。
///
/// 播完之后播放器的 `playing` 已经是 false，直接 `toggle()` 只会从最后一帧
/// 接着走（看上去像没反应）：底栏播放键、点画面、空格三条路径都要先回到
/// 开头再播，所以收敛到这一处，别各写一份。
Future<void> toggleVideoPlayback(VideoPlayback playback) async {
  if (playback.completed) {
    await playback.seek(Duration.zero);
    await playback.play();
    return;
  }
  await playback.toggle();
}

/// 建一个播放实例。用函数类型而不是直接给 Provider 一个实例：
/// 每个查看器都要独立播放器（同一个 Player 被两处 `Video` 绑会互相抢纹理）。
typedef VideoPlaybackFactory = VideoPlayback Function();

/// 真实实现走 `media_kit`。测试里覆盖这个 Provider。
final Provider<VideoPlaybackFactory> videoPlaybackFactoryProvider =
    Provider<VideoPlaybackFactory>((ref) => MediaKitVideoPlayback.new);

/// media_kit 实现。
///
/// 位置流按约 200ms 节流再通知：mpv 的 position 回调很密，
/// 每帧都 `notifyListeners` 会让整条控制栏（滑块 + 时间文本）跟着重建。
class MediaKitVideoPlayback extends VideoPlayback {
  MediaKitVideoPlayback() {
    MediaKit.ensureInitialized();
    _player = Player();
    _controller = VideoController(_player);
    _bind();
  }

  /// 位置通知的最小间隔。
  static const Duration _positionInterval = Duration(milliseconds: 200);

  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  bool _playing = false;
  bool _buffering = false;
  bool _ready = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1;
  double _speed = 1;
  String? _error;

  DateTime _lastPositionNotify = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  bool get playing => _playing;

  @override
  bool get buffering => _buffering;

  @override
  bool get ready => _ready;

  @override
  bool get completed => _completed;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  double get volume => _volume;

  @override
  double get speed => _speed;

  @override
  String? get error => _error;

  void _bind() {
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      _player.stream.playing.listen((value) {
        _playing = value;
        notifyListeners();
      }),
      _player.stream.buffering.listen((value) {
        _buffering = value;
        notifyListeners();
      }),
      _player.stream.completed.listen((value) {
        _completed = value;
        notifyListeners();
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        if (value > Duration.zero) {
          _ready = true;
        }
        notifyListeners();
      }),
      _player.stream.volume.listen((value) {
        // mpv 的音量是 0–100。
        _volume = (value / 100).clamp(0, 1).toDouble();
        notifyListeners();
      }),
      _player.stream.rate.listen((value) {
        _speed = value;
        notifyListeners();
      }),
      _player.stream.position.listen((value) {
        _position = value;
        final now = DateTime.now();
        if (now.difference(_lastPositionNotify) >= _positionInterval) {
          _lastPositionNotify = now;
          notifyListeners();
        }
      }),
      _player.stream.error.listen((value) {
        _error = value;
        notifyListeners();
      }),
    ]);
  }

  @override
  Future<void> open(File file) async {
    _error = null;
    _completed = false;
    _ready = false;
    _duration = Duration.zero;
    _position = Duration.zero;
    notifyListeners();
    await _player.open(Media(Uri.file(file.path).toString()));
    await _player.setVolume(100);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> toggle() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume.clamp(0, 1) * 100).toDouble());

  @override
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  @override
  Widget buildSurface() {
    return Video(
      controller: _controller,
      // 控件由我们画（`VideoControls` 那套是移动端手势思路，
      // 与右栏面板 32dp 的底栏不是一种语言）。
      controls: NoVideoControls,
      fit: BoxFit.contain,
      // 字幕走文件内嵌轨道时由 media_kit 自己的字幕层画，样式贴近默认即可。
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        style: TextStyle(fontSize: 14),
      ),
    );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    unawaited(_player.dispose());
    super.dispose();
  }
}
