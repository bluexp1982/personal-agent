import 'dart:convert';

import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/core/tls_pinning.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('certificateFingerprint', () {
    test('与服务端 format_digest 的口径一致（base32(sha256) 前 16 字符分四组）', () {
      // 固定向量：sha256("hello") 的 base32 前 16 字符，每 4 个一组。
      // 这个值由服务端同一套算法独立算出，两边任何一个改动都会让它失败。
      expect(
        certificateFingerprint(utf8.encode('hello')),
        'FTZE-3OS7-WCRQ-4JXI',
      );
    });

    test('总是四组、每组四个字符', () {
      for (final input in <List<int>>[
        <int>[],
        <int>[0],
        List<int>.generate(64, (i) => i),
      ]) {
        final fingerprint = certificateFingerprint(input);
        final groups = fingerprint.split('-');
        expect(groups.length, 4, reason: '指纹必须固定四组');
        expect(groups.every((group) => group.length == 4), isTrue);
      }
    });
  });

  group('shouldAcceptCertificate', () {
    test('首次连接（无基准）接受', () {
      expect(shouldAcceptCertificate(observed: 'AAAA-BBBB-CCCC-DDDD'), isTrue);
    });

    test('空字符串等同于没有基准', () {
      expect(
        shouldAcceptCertificate(observed: 'AAAA-BBBB-CCCC-DDDD', pinned: ''),
        isTrue,
      );
    });

    test('与基准一致时接受', () {
      expect(
        shouldAcceptCertificate(
          observed: 'AAAA-BBBB-CCCC-DDDD',
          pinned: 'AAAA-BBBB-CCCC-DDDD',
        ),
        isTrue,
      );
    });

    test('与基准不一致时拒绝', () {
      expect(
        shouldAcceptCertificate(
          observed: 'AAAA-BBBB-CCCC-DDDD',
          pinned: 'EEEE-FFFF-GGGG-HHHH',
        ),
        isFalse,
      );
    });
  });

  group('canSubmitPairing', () {
    test('明文 http 不需要核对', () {
      expect(
        canSubmitPairing(
          serverUrl: 'http://127.0.0.1:8787',
          observedFingerprint: null,
          confirmed: false,
        ),
        isTrue,
      );
    });

    test('https 尚未探测到指纹时允许发起探测', () {
      expect(
        canSubmitPairing(
          serverUrl: 'https://192.168.1.10:8787',
          observedFingerprint: null,
          confirmed: false,
        ),
        isTrue,
      );
    });

    test('https 已看到指纹但未勾选时禁止提交', () {
      expect(
        canSubmitPairing(
          serverUrl: 'https://192.168.1.10:8787',
          observedFingerprint: 'AAAA-BBBB-CCCC-DDDD',
          confirmed: false,
        ),
        isFalse,
      );
    });

    test('https 已核对后允许提交', () {
      expect(
        canSubmitPairing(
          serverUrl: 'https://192.168.1.10:8787',
          observedFingerprint: 'AAAA-BBBB-CCCC-DDDD',
          confirmed: true,
        ),
        isTrue,
      );
    });
  });

  group('tls 失败的错误呈现', () {
    test('指纹不匹配给专用错误码，并明确不可重试', () {
      final error = ApiException.tlsPinning();
      expect(error.code, 'tls_fingerprint_mismatch');
      expect(error.retryable, isFalse);
      expect(error.userMessage, contains('解除配对'));
      // 不能误导用户去查端口/进程：那是 network_error 的处置方式。
      expect(error.userMessage, isNot(contains('端口')));
    });
  });
}
