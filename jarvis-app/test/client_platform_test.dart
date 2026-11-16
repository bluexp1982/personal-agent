import 'package:jarvis_app/src/core/client_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('defaultServerUrl', () {
    test('桌面默认连本机回环', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(defaultServerUrl(platform: platform), kDesktopServerUrl);
      }
    });

    test('手机端默认留空（本机地址在手机上永远连不上）', () {
      expect(defaultServerUrl(platform: TargetPlatform.android), '');
      expect(defaultServerUrl(platform: TargetPlatform.iOS), '');
    });
  });

  group('platformName', () {
    test('与服务端 pairing 的 platform 字段一致', () {
      expect(platformName(TargetPlatform.macOS), 'macos');
      expect(platformName(TargetPlatform.windows), 'windows');
      expect(platformName(TargetPlatform.linux), 'linux');
      expect(platformName(TargetPlatform.android), 'android');
      expect(platformName(TargetPlatform.iOS), 'ios');
    });
  });

  group('deviceLabel', () {
    test('手机不显示主机名', () {
      expect(
        deviceLabel(platform: TargetPlatform.android, hostname: 'localhost'),
        'Android 手机',
      );
      expect(
        deviceLabel(platform: TargetPlatform.iOS, hostname: 'localhost'),
        'iPhone',
      );
    });

    test('桌面带上主机名，便于一台人区分多台机器', () {
      expect(
        deviceLabel(platform: TargetPlatform.macOS, hostname: 'studio'),
        'Mac · studio',
      );
      expect(deviceLabel(platform: TargetPlatform.macOS, hostname: ''), 'Mac');
    });
  });

  group('serverUrlValidator', () {
    test('手机端拒绝空地址并给出可执行提示', () {
      final message = serverUrlValidator('', platform: TargetPlatform.iOS);
      expect(message, contains('局域网地址'));
    });

    test('手机端拒绝明文 http', () {
      final message = serverUrlValidator(
        'http://192.168.1.10:8787',
        platform: TargetPlatform.android,
      );
      expect(message, contains('https://'));
    });

    test('手机端接受局域网 https', () {
      expect(
        serverUrlValidator(
          'https://192.168.1.10:8787',
          platform: TargetPlatform.android,
        ),
        isNull,
      );
    });

    test('桌面允许回环明文', () {
      expect(
        serverUrlValidator(
          'http://127.0.0.1:8787',
          platform: TargetPlatform.macOS,
        ),
        isNull,
      );
    });

    test('缺协议时按 https 解析，不当成非法地址', () {
      expect(
        serverUrlValidator('192.168.1.10:8787', platform: TargetPlatform.macOS),
        isNull,
      );
    });

    test('明显非法的地址给出格式提示', () {
      final message = serverUrlValidator('://', platform: TargetPlatform.macOS);
      expect(message, isNotNull);
    });
  });
}
