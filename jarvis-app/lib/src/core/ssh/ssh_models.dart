// SSH 段的数据模型与纯函数。
//
// 这里刻意不依赖 Flutter：状态机、地址推导与错误归类都能直接单测，
// 界面只负责把 [SshState] 渲染出来。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../api_error.dart';

/// `/api/ssh/info` 的响应。字段名与服务端 `protocol::SshTunnelInfo` 一一对应。
class SshTunnelInfo {
  const SshTunnelInfo({
    required this.enabled,
    required this.target,
    required this.sshdReachable,
  });

  factory SshTunnelInfo.fromJson(Map<String, dynamic> json) {
    return SshTunnelInfo(
      enabled: json['enabled'] as bool? ?? false,
      target: json['target'] as String? ?? '',
      sshdReachable: json['sshd_reachable'] as bool? ?? false,
    );
  }

  /// 服务端是否开启隧道。
  final bool enabled;

  /// 隧道终点，形如 `127.0.0.1:22`（服务端配置决定，客户端不可改）。
  final String target;

  /// 终点当前是否可连。`enabled=false` 时服务端恒给 false。
  final bool sshdReachable;

  bool get ready => enabled && sshdReachable;
}

/// SSH 主机密钥。
///
/// `dartssh2` 的回调给的是原始指纹字节，这里统一转成 OpenSSH 风格的
/// `SHA256:...`：它与 `ssh-keygen -lf` 的输出一致，用户能用系统工具对一眼。
class SshHostKey {
  const SshHostKey({required this.type, required this.fingerprint});

  /// 密钥类型，例如 `ssh-ed25519`。
  final String type;

  /// `SHA256:<base64 无填充>`。
  final String fingerprint;

  @override
  String toString() => '$type $fingerprint';
}

/// 连接阶段。界面只在这个粒度重建，终端输出不写回状态。
enum SshPhase {
  /// 还没连过（显示连接表单）。
  idle,

  /// 正在预检 / 握手 / 认证。
  connecting,

  /// shell 已就绪。
  connected,

  /// 曾经连上，后来断开了。
  disconnected,

  /// 连接失败，`message` 里有原因。
  failed,
}

/// 失败归类。分开是为了让不同原因给出不同处置动作，而不是一句"连接失败"。
enum SshFailureKind {
  /// 服务端 `ssh.enabled=false`。
  tunnelDisabled,

  /// 服务端本机 sshd 不可达（没开远程登录 / 端口不对）。
  sshdUnreachable,

  /// 令牌失效（配对被解除或过期）。
  unauthenticated,

  /// 密码错误或多因素失败。
  authFailed,

  /// 主机密钥与首次记录不一致。
  hostKeyChanged,

  /// 服务端 TLS 证书与配对时记录的不一致（隧道连不上）。
  certificateRejected,

  /// 并发会话已达上限。
  tooManySessions,

  /// 网络层问题：服务不在线、隧道被中间设备断开等。
  network,

  /// 用户主动取消。
  canceled,

  /// 未归类的异常。
  unknown,
}

extension SshFailureHint on SshFailureKind {
  /// 可直接展示的一句话。每条都对应一个用户真的能做的动作。
  String get hint => switch (this) {
    SshFailureKind.tunnelDisabled =>
      '服务端没有开启 SSH 隧道：请把服务端配置里的 ssh.enabled 设为 true 后重启服务',
    SshFailureKind.sshdUnreachable =>
      '服务端本机的 sshd 连不上：请打开「远程登录 / SSH」（macOS 在系统设置 › 通用 › 共享），'
          '确认 22 端口在监听后重试',
    SshFailureKind.unauthenticated => '配对已失效，请在设置里重新登录或重新配对',
    SshFailureKind.authFailed => '用户名或密码不正确',
    SshFailureKind.hostKeyChanged =>
      '服务端 SSH 主机指纹已变化，已阻断连接：确认服务端没有重装或更换 sshd 后再继续',
    SshFailureKind.certificateRejected =>
      '服务端证书指纹与配对时不一致：若是重装或换了证书，请先在设置里解除配对并重新配对',
    SshFailureKind.tooManySessions => '同时打开的终端数已达上限，请先关闭其它终端',
    SshFailureKind.network => '连接中断：确认服务端在线、地址与端口可达，然后重试',
    SshFailureKind.canceled => '已取消连接',
    SshFailureKind.unknown => '连接失败，请查看服务端日志后重试',
  };
}

/// 由证书/密钥指纹字节生成 OpenSSH 风格字符串。
String sshHostKeyFingerprint(Uint8List bytes) {
  return 'SHA256:${base64Encode(bytes).replaceAll('=', '')}';
}

/// 由服务地址推导隧道地址：`http → ws`、`https → wss`，路径统一为 `/api/ssh`。
///
/// 不硬编码端口：服务端可能把 `api_bind` 换成别的端口，客户端连哪儿由已配对的
/// `serverUrl` 说了算——再写一份默认值只会造出"改了一处、另一处没改"的坑。
Uri sshTunnelUri(String serverUrl) {
  final base = Uri.parse(serverUrl.trim());
  final scheme = base.scheme.toLowerCase() == 'https' ? 'wss' : 'ws';
  final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
  return base.replace(scheme: scheme, path: '$prefix/api/ssh');
}

/// 把连接过程中的异常归类。
///
/// `dartssh2` 与 `dart:io` 抛出的类型很杂，界面不该逐个 `catch`：
/// 归到一档，才能保证"密码错"与"服务端没开 sshd"不会长成同一句话。
SshFailureKind classifySshError(Object error) {
  if (error is SshConnectException) {
    return error.kind;
  }
  if (error is ApiException) {
    return switch (error.code) {
      'unauthenticated' => SshFailureKind.unauthenticated,
      'rate_limited' => SshFailureKind.tooManySessions,
      'ssh_unavailable' || 'network_error' => SshFailureKind.sshdUnreachable,
      'tls_fingerprint_mismatch' => SshFailureKind.network,
      _ => SshFailureKind.unknown,
    };
  }
  if (error is SSHAuthError) {
    return SshFailureKind.authFailed;
  }
  if (error is SSHHostkeyError) {
    return SshFailureKind.hostKeyChanged;
  }
  if (error is TlsException) {
    return SshFailureKind.certificateRejected;
  }
  if (error is SocketException ||
      error is WebSocketException ||
      error is SSHSocketError ||
      error is SSHHandshakeError ||
      error is TimeoutException) {
    return SshFailureKind.network;
  }
  return SshFailureKind.unknown;
}

/// 连接层自己抛的异常：把"已经在服务端被拒绝的原因"带过界面，而不是退化成一句
/// "Connection failed"。
class SshConnectException implements Exception {
  const SshConnectException(this.kind, [this.detail]);

  final SshFailureKind kind;

  /// 面向开发者的补充信息（形如 HTTP 状态码），不直接展示给用户。
  final String? detail;

  String get userMessage => kind.hint;

  @override
  String toString() =>
      'SshConnectException(${kind.name}${detail == null ? '' : ', $detail'})';
}

/// 连接状态。终端实例不放在这里：它的输出每帧都在变，放进状态会让整棵树重绘。
class SshState {
  const SshState({
    required this.phase,
    this.message,
    this.failure,
    this.username = '',
    this.target = '',
    this.tunnelEnabled,
    this.sshdReachable,
  });

  const SshState.initial() : this(phase: SshPhase.idle);

  final SshPhase phase;

  /// 失败 / 断开时给用户看的一句话。
  final String? message;

  /// 失败归类；连接中与已连接时为 null。
  final SshFailureKind? failure;

  /// 上次成功连接用的用户名（表单回填）。
  final String username;

  /// 服务端报告的隧道终点，预检成功后才有值。
  final String target;

  /// 预检结果；还没探测过时为 null（界面显示"检测中"而不是"不可用"）。
  final bool? tunnelEnabled;
  final bool? sshdReachable;

  bool get isConnecting => phase == SshPhase.connecting;

  bool get isConnected => phase == SshPhase.connected;

  bool get hasTunnelInfo => tunnelEnabled != null;

  /// 预检明确不可用。`null`（还没探测）不算不可用，否则界面会在连接前闪一下红字。
  bool get tunnelUnavailable =>
      tunnelEnabled == false || sshdReachable == false;

  SshState copyWith({
    SshPhase? phase,
    String? message,
    SshFailureKind? failure,
    String? username,
    String? target,
    bool? tunnelEnabled,
    bool? sshdReachable,
    bool clearMessage = false,
    bool clearFailure = false,
  }) {
    return SshState(
      phase: phase ?? this.phase,
      message: clearMessage ? null : (message ?? this.message),
      failure: clearFailure ? null : (failure ?? this.failure),
      username: username ?? this.username,
      target: target ?? this.target,
      tunnelEnabled: tunnelEnabled ?? this.tunnelEnabled,
      sshdReachable: sshdReachable ?? this.sshdReachable,
    );
  }
}
