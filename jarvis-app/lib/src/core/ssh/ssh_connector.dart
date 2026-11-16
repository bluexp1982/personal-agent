// SSH 连接层：从 `/api/ssh/info` 预检到一条可用的 shell。
//
// 抽成接口是为了让状态机在测试里不碰网络：`SshController` 只依赖这里的方法，
// 真实实现（[TunnelSshConnector]）负责 WebSocket、TLS 指纹与 dartssh2 的全部细节。

import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:http/io_client.dart';

import '../api_client.dart';
import '../tls_pinning.dart';
import 'ssh_models.dart';
import 'ssh_tunnel_socket.dart';

/// 一条已就绪的 shell 的最小接口。
///
/// `SshController` 只依赖这几个方法，测试里才能用一个不发网络的 Fake 把
/// "连接成功之后的状态迁移"也覆盖掉——只测失败路径等于没测到主线。
abstract interface class SshShell {
  Stream<Uint8List> get stdout;

  /// shell 通道关闭（远端 exit / 隧道断开）。
  Future<void> get done;

  void write(List<int> data);

  void resizeTerminal(int cols, int rows);

  void close();
}

/// [SSHSession] 的薄适配层：把写接口统一成 `List<int>`，其余原样转发。
class DartSshShell implements SshShell {
  DartSshShell(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Future<void> get done => _session.done;

  @override
  void write(List<int> data) => _session.write(Uint8List.fromList(data));

  @override
  void resizeTerminal(int cols, int rows) =>
      _session.resizeTerminal(cols, rows);

  @override
  void close() => _session.close();
}

/// 一条可用的连接。
///
/// 释放顺序（会话 → SSH 连接 → HTTP 客户端）收起在 [close] 里：
/// 反过来先关 HttpClient，关闭帧发不出去，服务端只能干等超时。
class SshConnection {
  const SshConnection({required this.shell, required this.onClose});

  final SshShell shell;
  final Future<void> Function() onClose;

  Future<void> close() => onClose();
}

/// 连接层接口。真实实现见 [TunnelSshConnector]，测试里注入 Fake。
abstract interface class SshConnector {
  /// 预检隧道：服务端是否开启、sshd 是否可达。
  Future<SshTunnelInfo> probe({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
  });

  /// 建立 shell。任何失败都以 [SshConnectException] 或原始异常抛出，
  /// 归类交给 [classifySshError]。
  Future<SshConnection> open({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
    required String username,
    required String password,
    required Future<bool> Function(SshHostKey key) verifyHostKey,
    int cols = 80,
    int rows = 24,
    Duration timeout = const Duration(seconds: 20),
  });
}

/// 经 `/api/ssh` 隧道的实现。
class TunnelSshConnector implements SshConnector {
  const TunnelSshConnector();

  @override
  Future<SshTunnelInfo> probe({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
  }) async {
    final client = ApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: IOClient(
        createPinnedHttpClient(baseUrl: baseUrl, pinned: tlsFingerprint),
      ),
    );
    try {
      return SshTunnelInfo.fromJson(await client.getJson('/api/ssh/info'));
    } finally {
      // 这次探测独占一个 HttpClient，用完就关，不跨请求复用。
      client.close();
    }
  }

  @override
  Future<SshConnection> open({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
    required String username,
    required String password,
    required Future<bool> Function(SshHostKey key) verifyHostKey,
    int cols = 80,
    int rows = 24,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final httpClient = createPinnedHttpClient(
      baseUrl: baseUrl,
      pinned: tlsFingerprint,
    );

    SshTunnelSocket? socket;
    SSHClient? client;
    try {
      socket = await SshTunnelSocket.connect(
        uri: sshTunnelUri(baseUrl),
        token: token,
        httpClient: httpClient,
        timeout: timeout,
      );

      client = SSHClient(
        socket,
        username: username,
        // 密码只在内存里出现一次：dartssh2 认证成功后不会保留它。
        onPasswordRequest: () => password,
        onVerifyHostKey: (type, fingerprint) => verifyHostKey(
          SshHostKey(
            type: type,
            fingerprint: sshHostKeyFingerprint(fingerprint),
          ),
        ),
        // 默认没有超时：隧道断在半路时会让界面一直转圈。
        handshakeTimeout: timeout,
        authTimeout: timeout,
      );

      final session = await client.shell(
        pty: SSHPtyConfig(width: cols, height: rows),
      );

      final shell = DartSshShell(session);
      return SshConnection(
        shell: shell,
        onClose: () async {
          try {
            shell.close();
          } on Object {
            // 已经断开时重复关闭会抛异常，这里没有可补救的动作。
          }
          try {
            await client!.close();
          } on Object {
            // 同上。
          }
          httpClient.close(force: true);
        },
      );
    } on Object {
      if (client != null) {
        await client.close().catchError((_) {});
      } else {
        socket?.destroy();
      }
      httpClient.close(force: true);
      rethrow;
    }
  }
}
