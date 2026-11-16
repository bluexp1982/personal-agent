import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 录音期间的「原生保活」开关。
///
/// 只有 Android 需要：切后台/锁屏后系统会降权后台进程，AudioRecord 随之被掐断，
/// 必须挂一个 `microphone` 类型的前台服务 + 常驻通知才能继续采集。
/// iOS 靠 `Info.plist` 的 `UIBackgroundModes: audio`，桌面三端不会因为切后台
/// 被挂起，所以这三类平台是 no-op。
abstract class RecordingForeground {
  /// 录音真正开始后调用（权限、账本、采集流都就绪）。
  Future<void> start();

  /// 暂停、停止或启动失败时调用，撤掉常驻通知。
  Future<void> stop();
}

/// 走 `MethodChannel` 的默认实现。
class PlatformRecordingForeground implements RecordingForeground {
  const PlatformRecordingForeground();

  /// 与 `MainActivity.kt` 里的通道名一字不差。
  static const MethodChannel _channel = MethodChannel(
    'personal_agent/recording_background',
  );

  /// 只有 Android 有这条原生实现；别处调用既无实现也无必要。
  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> start() => _invoke('start');

  @override
  Future<void> stop() => _invoke('stop');

  Future<void> _invoke(String method) async {
    if (!_supported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException catch (error) {
      // 保活失败绝不反过来打断录音：宁可只在前台录，也不要丢掉正在录的内容。
      // 系统拒绝（例如后台启动限制、通知被禁）都在这里降级，不往上抛。
      debugPrint('录音前台服务 $method 失败：${error.message}');
    } on MissingPluginException catch (error) {
      debugPrint('录音前台服务不可用（$method）：$error');
    }
  }
}
