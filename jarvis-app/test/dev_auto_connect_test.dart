import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_app/src/core/dev_auto_connect.dart';

void main() {
  test('没有注入参数时自动配对保持关闭', () {
    // 常规 `flutter run` / 打出来的包都不带这两个 define，功能必须默认关闭。
    expect(DevAutoConnect.enabled, isFalse);
    expect(DevAutoConnect.serverUrl, isEmpty);
    expect(DevAutoConnect.pairCode, isEmpty);
  });

  test('服务端明确不认这台设备时才清身份', () {
    for (final code in <String>[
      'unauthenticated',
      'forbidden',
      'not_found',
      'tls_fingerprint_mismatch',
    ]) {
      expect(shouldForgetAfterLoginFailure(code), isTrue, reason: code);
    }
  });

  test('网络不通与无关错误都不清身份', () {
    for (final code in <String?>[
      null,
      '',
      'network_error',
      'rate_limited',
      'internal_error',
      'conflict',
    ]) {
      expect(shouldForgetAfterLoginFailure(code), isFalse, reason: '$code');
    }
  });
}
