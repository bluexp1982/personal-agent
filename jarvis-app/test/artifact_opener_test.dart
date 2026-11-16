import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/artifact_opener.dart';

void main() {
  group('openCommandFor', () {
    test('桌面三个平台各有自己的打开命令', () {
      expect(
        openCommandFor(TargetPlatform.macOS, '/tmp/a.mp4'),
        <String>['open', '/tmp/a.mp4'],
      );
      expect(
        openCommandFor(TargetPlatform.linux, '/tmp/a.mp4'),
        <String>['xdg-open', '/tmp/a.mp4'],
      );
      // Windows 的 `start` 第一个引号参数是窗口标题，必须占位，
      // 否则路径会被当成标题，什么都不会打开。
      expect(
        openCommandFor(TargetPlatform.windows, r'C:\tmp\a.mp4'),
        <String>['cmd', '/c', 'start', '', r'C:\tmp\a.mp4'],
      );
    });

    test('移动端没有命令行通道，走分享面板', () {
      expect(openCommandFor(TargetPlatform.android, '/tmp/a.mp4'), isNull);
      expect(openCommandFor(TargetPlatform.iOS, '/tmp/a.mp4'), isNull);
    });
  });

  group('createArtifactOpener', () {
    test('手机用分享面板', () {
      expect(
        createArtifactOpener(platform: TargetPlatform.android),
        isA<MobileArtifactOpener>(),
      );
      expect(
        createArtifactOpener(platform: TargetPlatform.iOS),
        isA<MobileArtifactOpener>(),
      );
    });

    test('桌面用系统默认程序', () {
      final opener = createArtifactOpener(platform: TargetPlatform.macOS);
      expect(opener, isA<DesktopArtifactOpener>());
      expect((opener as DesktopArtifactOpener).platform, TargetPlatform.macOS);
    });
  });
}
