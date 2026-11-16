import 'dart:typed_data';

import 'package:record/record.dart';

/// 采集层异常。文案直接展示给用户，写清"该去做什么"。
class AudioCaptureException implements Exception {
  const AudioCaptureException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 麦克风采集接口。
///
/// 抽象出来的原因有两个：widget 测试不能真的开麦克风；
/// 将来要换 sherpa / 原生实现时，控制器不该跟着改。
abstract class AudioCapture {
  /// 是否已获得麦克风权限（必要时会触发系统授权弹窗）。
  Future<bool> requestPermission();

  /// 开始采集 16kHz 单声道 PCM16，返回持续的字节流。
  Future<Stream<Uint8List>> start();

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<void> dispose();
}

/// 基于 `record` 的实现：macOS/iOS 走 AVFoundation，Android 走 AudioRecord。
class RecordAudioCapture implements AudioCapture {
  RecordAudioCapture({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  static const RecordConfig _config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    // 会议/笔记场景默认关闭自动增益：音量条与断句阈值都需要稳定的输入。
    autoGain: false,
    echoCancel: false,
    noiseSuppress: false,
    // 显式固化 iOS 的音频会话选项，不吃插件默认值：录音走
    // playAndRecord + 扬声器 / 蓝牙，锁屏或切后台时 session 才能保持激活。
    // 「后台继续采集」本身由 Info.plist 的 `UIBackgroundModes: audio` 声明，
    // 这里只负责路由与选项。
    iosConfig: IosRecordConfig(
      categoryOptions: <IosAudioCategoryOption>[
        IosAudioCategoryOption.defaultToSpeaker,
        IosAudioCategoryOption.allowBluetooth,
        IosAudioCategoryOption.allowBluetoothA2DP,
      ],
    ),
    // 来电、闹钟、系统弹窗会打断音频会话。默认的 `pause` 只暂停不恢复，
    // 打断结束后录音会永久停在暂停态（用户看到"还在录"、其实没数据）；
    // `pauseResume` 会等系统给出 shouldResume 时自动 setActive + resume。
    audioInterruption: AudioInterruptionMode.pauseResume,
  );

  @override
  Future<bool> requestPermission() async {
    try {
      return await _recorder.hasPermission();
    } on Exception catch (error) {
      throw AudioCaptureException('无法获取麦克风权限：$error');
    }
  }

  @override
  Future<Stream<Uint8List>> start() async {
    try {
      return await _recorder.startStream(_config);
    } on Exception catch (error) {
      throw AudioCaptureException('无法开始录音：$error');
    }
  }

  @override
  Future<void> pause() async {
    try {
      await _recorder.pause();
    } on Exception catch (error) {
      throw AudioCaptureException('暂停录音失败：$error');
    }
  }

  @override
  Future<void> resume() async {
    try {
      await _recorder.resume();
    } on Exception catch (error) {
      throw AudioCaptureException('继续录音失败：$error');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _recorder.stop();
    } on Exception catch (error) {
      throw AudioCaptureException('停止录音失败：$error');
    }
  }

  @override
  Future<void> dispose() async {
    await _recorder.dispose();
  }
}
