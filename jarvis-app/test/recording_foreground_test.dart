import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/recording/recording_foreground.dart';

/// 与 `MainActivity.kt` 里的通道名一致；改任何一边都要同步。
const MethodChannel _channel = MethodChannel(
  'personal_agent/recording_background',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];

  void mockChannel({bool fail = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          if (fail) {
            throw PlatformException(
              code: 'foreground_service_failed',
              message: '系统拒绝',
            );
          }
          return null;
        });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android 上 start / stop 各转发一次原生调用', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockChannel();

    const foreground = PlatformRecordingForeground();
    await foreground.start();
    await foreground.stop();

    expect(calls, <String>['start', 'stop']);
  });

  test('iOS / 桌面不走前台服务，一个调用都不发', () async {
    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      calls.clear();
      debugDefaultTargetPlatformOverride = platform;
      mockChannel();

      const foreground = PlatformRecordingForeground();
      await foreground.start();
      await foreground.stop();

      expect(calls, isEmpty, reason: '$platform 不需要前台服务');
    }
  });

  test('原生拒绝时只降级，不把异常抛回录音流程', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockChannel(fail: true);

    const foreground = PlatformRecordingForeground();

    // 调用方是 `unawaited(_foreground.start())`：抛异常会直接变成未捕获错误。
    await expectLater(foreground.start(), completes);
    expect(calls, <String>['start']);
  });
}
