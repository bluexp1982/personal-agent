import 'dart:io';
import 'dart:typed_data';

import 'package:jarvis_app/src/core/api_error.dart';
import 'package:jarvis_app/src/core/ssh/ssh_models.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sshTunnelUri', () {
    test('明文服务地址映射到 ws，并保留端口', () {
      final uri = sshTunnelUri('http://192.168.1.10:8787');
      expect(uri.scheme, 'ws');
      expect(uri.host, '192.168.1.10');
      expect(uri.port, 8787);
      expect(uri.path, '/api/ssh');
    });

    test('https 映射到 wss，不丢端口与已有前缀', () {
      final uri = sshTunnelUri('https://phone.example:9443/agent/');
      expect(uri.scheme, 'wss');
      expect(uri.port, 9443);
      expect(uri.path, '/agent/api/ssh');
    });

    test('默认端口不写死在路径里', () {
      // 服务端换了 api_bind 端口时，客户端必须跟着 serverUrl 走。
      expect(
        sshTunnelUri('http://127.0.0.1:9000').toString(),
        'ws://127.0.0.1:9000/api/ssh',
      );
    });
  });

  group('sshHostKeyFingerprint', () {
    test('生成 OpenSSH 风格的 SHA256 且不带填充', () {
      final fingerprint = sshHostKeyFingerprint(
        Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      expect(fingerprint.startsWith('SHA256:'), isTrue);
      expect(fingerprint.contains('='), isFalse);
      expect(fingerprint, 'SHA256:AQIDBA');
    });
  });

  group('classifySshError', () {
    test('自定义异常原样透传', () {
      expect(
        classifySshError(
          const SshConnectException(SshFailureKind.tunnelDisabled),
        ),
        SshFailureKind.tunnelDisabled,
      );
    });

    test('服务端错误码映射到可执行的下一步', () {
      expect(
        classifySshError(
          const ApiException(
            code: 'unauthenticated',
            message: 'x',
            retryable: false,
            hint: 'h',
          ),
        ),
        SshFailureKind.unauthenticated,
      );
      expect(
        classifySshError(
          const ApiException(
            code: 'ssh_unavailable',
            message: 'x',
            retryable: true,
            hint: 'h',
          ),
        ),
        SshFailureKind.sshdUnreachable,
      );
      expect(
        classifySshError(
          const ApiException(
            code: 'rate_limited',
            message: 'x',
            retryable: true,
            hint: 'h',
          ),
        ),
        SshFailureKind.tooManySessions,
      );
    });

    test('dartssh2 的认证与主机密钥异常分开归类', () {
      expect(
        classifySshError(SSHAuthFailError('bad')),
        SshFailureKind.authFailed,
      );
      expect(
        classifySshError(SSHHostkeyError('changed')),
        SshFailureKind.hostKeyChanged,
      );
    });

    test('网络异常与证书异常不是同一类', () {
      expect(
        classifySshError(const SocketException('refused')),
        SshFailureKind.network,
      );
      expect(
        classifySshError(const HandshakeException('bad cert')),
        SshFailureKind.certificateRejected,
      );
    });
  });

  group('SshState', () {
    test('还没探测过时不算"不可用"', () {
      const state = SshState.initial();
      expect(state.hasTunnelInfo, isFalse);
      expect(state.tunnelUnavailable, isFalse, reason: '否则进页面会闪一下红字');
    });

    test('copyWith 能清空上一次的错误', () {
      final failed = const SshState.initial().copyWith(
        phase: SshPhase.failed,
        failure: SshFailureKind.authFailed,
        message: '密码错误',
      );
      final cleared = failed.copyWith(
        phase: SshPhase.connected,
        clearMessage: true,
        clearFailure: true,
      );

      expect(cleared.phase, SshPhase.connected);
      expect(cleared.message, isNull);
      expect(cleared.failure, isNull);
    });

    test('每种失败都有可展示的处置提示', () {
      for (final kind in SshFailureKind.values) {
        expect(kind.hint, isNotEmpty, reason: '${kind.name} 缺少提示');
      }
    });
  });

  group('SshTunnelInfo', () {
    test('ready 要求同时开启且可达', () {
      expect(
        const SshTunnelInfo(
          enabled: true,
          target: '127.0.0.1:22',
          sshdReachable: true,
        ).ready,
        isTrue,
      );
      expect(
        const SshTunnelInfo(
          enabled: true,
          target: '127.0.0.1:22',
          sshdReachable: false,
        ).ready,
        isFalse,
      );
    });

    test('字段缺失时保守按不可用处理', () {
      final info = SshTunnelInfo.fromJson(const <String, dynamic>{});
      expect(info.enabled, isFalse);
      expect(info.sshdReachable, isFalse);
      expect(info.target, isEmpty);
    });
  });
}
