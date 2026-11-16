// 把 `/api/ssh` 的 WebSocket 包装成 dartssh2 需要的 [SSHSocket]。
//
// 服务端只做字节透传：WebSocket 的 Binary 帧 ⇄ 本机 sshd 的 TCP 流。
// 因此这里不做任何 SSH 协议层的事，只负责"上层写进来的字节变成二进制帧，
// 收到的二进制帧变成字节流"。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// 一条指向服务端 SSH 隧道的 socket。
class SshTunnelSocket extends SSHSocket {
  SshTunnelSocket._(this._ws) {
    _subscription = _ws.listen(
      _handleEvent,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: true,
    );

    // 出站也走一个 controller：dartssh2 会同时从握手与业务逻辑往 sink 写，
    // 直接透传给 WebSocket 无法感知"已经关了"，抛出的 StateError 会冒到协议层。
    _outgoingSubscription = _outgoing.stream.listen(
      _handleOutgoing,
      onError: (_, _) {},
      onDone: _closeTransport,
    );
  }

  /// 建立连接。
  ///
  /// [httpClient] 必须是 [`createPinnedHttpClient`] 产出、绑好证书指纹的那一个：
  /// WebSocket 握手与普通 HTTP 请求走同一套信任判断，不能有第二份实现。
  static Future<SshTunnelSocket> connect({
    required Uri uri,
    required String token,
    required HttpClient httpClient,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: <String, dynamic>{'authorization': 'Bearer $token'},
      customClient: httpClient,
    ).timeout(timeout);

    // 隧道只传字节：文本帧说明对端不是本协议，静默忽略会让排查变得极难。
    socket.pingInterval = const Duration(seconds: 20);
    return SshTunnelSocket._(socket);
  }

  final WebSocket _ws;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final StreamController<List<int>> _outgoing = StreamController<List<int>>();
  final Completer<void> _done = Completer<void>();

  late final StreamSubscription<dynamic> _subscription;
  late final StreamSubscription<List<int>> _outgoingSubscription;

  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    await _closeTransport();
    return done;
  }

  @override
  void destroy() {
    _subscription.cancel().ignore();
    _outgoingSubscription.cancel().ignore();
    _ws.close(WebSocketStatus.goingAway).ignore();
    _finish(null);
  }

  /// 出站没有额外缓冲，写进 WebSocket 就已经交给内核了。
  @override
  Future<void> flush() async {}

  void _handleEvent(dynamic event) {
    if (event is List<int>) {
      if (!_incoming.isClosed) {
        _incoming.add(Uint8List.fromList(event));
      }
      return;
    }
    // 文本帧：服务端已经声明只发二进制，这里遇到就当成协议错误收尾。
    _handleError(const SshTunnelProtocolError('unexpected text frame'));
  }

  void _handleOutgoing(List<int> data) {
    if (_ws.readyState != WebSocket.open) {
      _handleError(const SshTunnelProtocolError('tunnel already closed'));
      return;
    }
    try {
      _ws.add(Uint8List.fromList(data));
    } on StateError catch (error) {
      _handleError(error);
    }
  }

  Future<void> _closeTransport() async {
    if (_closed) {
      return;
    }
    _closed = true;
    if (!_outgoing.isClosed) {
      await _outgoing.close();
    }
    await _ws.close(WebSocketStatus.normalClosure).catchError((_) {});
    _finish(null);
  }

  void _handleError(Object error) {
    _finish(error);
    _subscription.cancel().ignore();
    _ws.close(WebSocketStatus.protocolError).ignore();
  }

  void _handleDone() => _finish(null);

  /// 只完成一次：`close()` 与 `onDone` 可能先后到达。
  void _finish(Object? error) {
    if (!_done.isCompleted) {
      if (error == null) {
        _done.complete();
      } else {
        _done.completeError(error);
      }
    }
    if (!_incoming.isClosed) {
      _incoming.close();
    }
    if (!_outgoing.isClosed) {
      _outgoing.close();
    }
  }
}

/// 隧道两侧的协议约定被破坏（对端发了文本帧、或往已关闭的隧道写数据）。
class SshTunnelProtocolError implements Exception {
  const SshTunnelProtocolError(this.message);

  final String message;

  @override
  String toString() => 'SshTunnelProtocolError($message)';
}
