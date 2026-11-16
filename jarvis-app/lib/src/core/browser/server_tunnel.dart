import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../tls_pinning.dart';

/// 隧道失败的原因。与界面上的三个动作一一对应，不做"统一网络错误"。
enum ServerTunnelFailure {
  /// 目标端口不在服务端白名单，或不是回环地址。
  denied,

  /// 服务端没开浏览器隧道，或目标端口拒连。
  unavailable,

  /// 令牌失效，需要重新登录。
  unauthenticated,

  /// 连不上服务端本身。
  network,
}

class ServerTunnelException implements Exception {
  const ServerTunnelException(this.failure, this.message, {this.statusCode});

  final ServerTunnelFailure failure;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ServerTunnelException(${failure.name}, $message)';
}

/// 把本机回环端口上的 TCP 连接转成 `/api/browser/tunnel` 的 WebSocket。
///
/// 一个网页通常会同时开 6 到 10 条连接，所以这里**每条 TCP 连接对应一条 WS**，
/// 不做多路复用：服务端只需做字节泵送，页面侧不需要任何改写。
class ServerTunnelBridge {
  ServerTunnelBridge._({
    required this.localPort,
    required this.target,
    required this._listener,
    required this._httpClient,
    required this._baseUrl,
    required this._token,
    required this._timeout,
    required this._maxConnections,
  });

  final int localPort;

  /// 服务端侧的 `host:port`，用于日志与排障。
  final String target;

  final ServerSocket _listener;
  final HttpClient _httpClient;
  final String _baseUrl;
  final String _token;
  final Duration _timeout;
  final int _maxConnections;

  final Set<WebSocket> _sockets = <WebSocket>{};
  final Set<Socket> _clients = <Socket>{};
  int _active = 0;
  bool _closed = false;

  Uri get baseUri => Uri.parse('http://127.0.0.1:$localPort/');

  static Future<ServerTunnelBridge> start({
    required String baseUrl,
    required String token,
    required String? tlsFingerprint,
    required String target,
    Duration timeout = const Duration(seconds: 15),
    int maxConnections = 24,
  }) async {
    final httpClient = createPinnedHttpClient(
      baseUrl: baseUrl,
      pinned: tlsFingerprint,
    );

    try {
      // 先探一次：把"没开 / 端口不允许 / 端口没起来"在 WebView 导航前就变成
      // 一句可执行的提示，而不是让页面先白屏再等资源超时。
      final probe = await _connect(
        httpClient: httpClient,
        baseUrl: baseUrl,
        token: token,
        target: target,
        timeout: timeout,
      );
      await probe.close();

      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final bridge = ServerTunnelBridge._(
        localPort: listener.port,
        target: target,
        listener: listener,
        httpClient: httpClient,
        baseUrl: baseUrl,
        token: token,
        timeout: timeout,
        maxConnections: maxConnections,
      );
      bridge._accept();
      return bridge;
    } on Object {
      httpClient.close(force: true);
      rethrow;
    }
  }

  void _accept() {
    _listener.listen(
      (socket) {
        if (_closed || _active >= _maxConnections) {
          socket.destroy();
          return;
        }
        _active++;
        _clients.add(socket);
        unawaited(_serve(socket));
      },
      onError: (Object error) {
        if (kDebugMode) {
          debugPrint('浏览器桥接监听失败：$error');
        }
      },
      cancelOnError: false,
    );
  }

  Future<void> _serve(Socket socket) async {
    WebSocket? socketWs;
    try {
      socketWs = await _connect(
        httpClient: _httpClient,
        baseUrl: _baseUrl,
        token: _token,
        target: target,
        timeout: _timeout,
      );
      if (_closed) {
        await socketWs.close();
        return;
      }
      _sockets.add(socketWs);

      final finished = Completer<void>();
      void finish() {
        if (!finished.isCompleted) {
          finished.complete();
        }
      }

      final upstream = socket.listen(
        (data) {
          final ws = socketWs;
          if (ws != null && ws.readyState == WebSocket.open) {
            ws.add(data);
          }
        },
        onDone: finish,
        onError: (Object _, StackTrace _) => finish(),
        cancelOnError: true,
      );

      // addStream 会把 WebSocket 的背压传导到 socket：页面下载大文件时
      // 内存不会随"收到的字节"一起涨。
      final downstream = socket.addStream(
        socketWs.where((event) => event is List<int>).cast<List<int>>(),
      );
      unawaited(
        downstream
            .catchError((Object error) {
              // 对端提前关闭是常态，不是错误；结束信号由 finished 负责。
            })
            .whenComplete(finish),
      );

      await finished.future;
      await upstream.cancel();
      await socketWs.close();
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('浏览器桥接单连接结束：$error');
      }
    } finally {
      if (socketWs != null) {
        _sockets.remove(socketWs);
      }
      _clients.remove(socket);
      socket.destroy();
      _active--;
    }
  }

  static Future<WebSocket> _connect({
    required HttpClient httpClient,
    required String baseUrl,
    required String token,
    required String target,
    required Duration timeout,
  }) async {
    final base = Uri.parse(baseUrl);
    final uri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/browser/tunnel',
      queryParameters: <String, String>{'target': target},
      fragment: '',
    );

    try {
      return await WebSocket.connect(
        uri.toString(),
        headers: <String, dynamic>{'authorization': 'Bearer $token'},
        customClient: httpClient,
      ).timeout(timeout);
    } on TimeoutException {
      throw const ServerTunnelException(ServerTunnelFailure.network, '连接服务端超时');
    } on WebSocketException catch (error) {
      final status = error.httpStatusCode;
      final message = error.message;
      if (status == 403) {
        throw ServerTunnelException(
          ServerTunnelFailure.denied,
          message,
          statusCode: status,
        );
      }
      if (status == 503) {
        throw ServerTunnelException(
          ServerTunnelFailure.unavailable,
          message,
          statusCode: status,
        );
      }
      if (status == 401) {
        throw ServerTunnelException(
          ServerTunnelFailure.unauthenticated,
          message,
          statusCode: status,
        );
      }
      throw ServerTunnelException(
        ServerTunnelFailure.network,
        message,
        statusCode: status,
      );
    } on SocketException catch (error) {
      throw ServerTunnelException(ServerTunnelFailure.network, error.message);
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

    await _listener.close();
    for (final ws in _sockets.toList(growable: false)) {
      await ws.close().catchError((_) {});
    }
    for (final socket in _clients.toList(growable: false)) {
      socket.destroy();
    }
    _sockets.clear();
    _clients.clear();
    _httpClient.close(force: true);
  }
}
