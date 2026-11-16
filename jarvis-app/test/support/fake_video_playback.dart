import 'dart:io';

import 'package:flutter/material.dart';
import 'package:jarvis_app/src/features/preview/video_playback.dart';

/// 纯 Dart 假播放器。
///
/// 真实现会构造 media_kit 的 `Player`（碰 libmpv 原生库），测试里只关心
/// "控件有没有把动作传下去"与"宿主切换有没有释放旧实例"。
class FakeVideoPlayback extends VideoPlayback {
  FakeVideoPlayback({
    Duration duration = const Duration(seconds: 30),
    this.errorOnOpen,
  }) : _durationValue = duration;

  /// 非空时模拟解码 / 打开失败。
  final String? errorOnOpen;

  bool _playing = false;
  Duration _position = Duration.zero;

  /// 字段名与 getter 刻意不同：同名会让 getter 无法覆盖。
  final Duration _durationValue;
  double _volume = 1;
  double _speed = 1;
  String? _error;

  /// 模拟"播完了"：真实现的 `completed` 来自 mpv 事件流，测试里直接写。
  @override
  bool completed = false;

  final List<Duration> seeks = <Duration>[];
  final List<double> speeds = <double>[];
  final List<double> volumes = <double>[];
  int opens = 0;
  bool disposed = false;

  @override
  bool get playing => _playing;

  @override
  bool get buffering => false;

  @override
  bool get ready => true;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _durationValue;

  @override
  double get volume => _volume;

  @override
  double get speed => _speed;

  @override
  String? get error => _error;

  @override
  Future<void> open(File file) async {
    opens += 1;
    if (errorOnOpen != null) {
      _error = errorOnOpen;
      notifyListeners();
    }
  }

  @override
  Future<void> play() async {
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> toggle() async {
    if (_playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _position = position;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    _volume = volume;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double speed) async {
    speeds.add(speed);
    _speed = speed;
    notifyListeners();
  }

  @override
  Widget buildSurface() =>
      const ColoredBox(color: Color(0xFF101010), key: Key('fake-surface'));

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
