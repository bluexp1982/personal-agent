import 'dart:convert';
import 'dart:io';

import 'package:jarvis_app/src/core/browser/server_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假服务端：把 `/api/browser/tunnel` 的每条 WS 接到一个回环 echo 端口。
///
/// 不校验令牌、不做白名单——那是服务端集成测试的职责；这里只验证客户端桥接
/// 的字节泵送、探测握手与释放顺序。
Future<HttpServer> _fakeServer(int echoPort) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path != '/api/browser/tunnel' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final ws = await WebSocketTransformer.upgrade(request);
    final upstream = await Socket.connect('127.0.0.1', echoPort);
    ws.listen(
      (event) {
        if (event is List<int>) {
          upstream.add(event);
        }
      },
      onDone: () => upstream.destroy(),
      onError: (Object _) => upstream.destroy(),
    );
    upstream.listen(
      (data) => ws.add(data),
      onDone: () => ws.close(),
      onError: (Object _) => ws.close(),
    );
  });
  return server;
}

void main() {
  test('桥接器把本地端口的字节透传到 WebSocket，并能正常释放', () async {
    // 上游 echo：收到什么回什么。
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((socket) {
      socket.listen(socket.add, onError: (Object _) {});
    });

    final server = await _fakeServer(echo.port);
    final bridge = await ServerTunnelBridge.start(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'test-token',
      tlsFingerprint: null,
      target: '127.0.0.1:9',
      timeout: const Duration(seconds: 3),
    );

    final client = await Socket.connect('127.0.0.1', bridge.localPort);
    client.add(utf8.encode('ping'));
    await client.flush();

    final echoed = await client
        .timeout(const Duration(seconds: 3))
        .first;
    expect(utf8.decode(echoed), 'ping');

    await client.close();
    await bridge.close();
    // 关闭后再连本地端口必须失败：监听已经收掉了。
    await expectLater(
      Socket.connect('127.0.0.1', bridge.localPort),
      throwsA(isA<SocketException>()),
    );

    await server.close(force: true);
    await echo.close();
  });

  test('服务端拒绝时把 403 / 503 映射成不同失败原因', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final code = request.uri.queryParameters['target'] == 'forbidden'
          ? HttpStatus.forbidden
          : HttpStatus.serviceUnavailable;
      request.response.statusCode = code;
      request.response.write('{"code":"x"}');
      await request.response.close();
    });

    final base = 'http://127.0.0.1:${server.port}';
    await expectLater(
      ServerTunnelBridge.start(
        baseUrl: base,
        token: 't',
        tlsFingerprint: null,
        target: 'forbidden',
      ),
      throwsA(
        isA<ServerTunnelException>().having(
          (error) => error.failure,
          'failure',
          ServerTunnelFailure.denied,
        ),
      ),
    );
    await expectLater(
      ServerTunnelBridge.start(
        baseUrl: base,
        token: 't',
        tlsFingerprint: null,
        target: 'down',
      ),
      throwsA(
        isA<ServerTunnelException>().having(
          (error) => error.failure,
          'failure',
          ServerTunnelFailure.unavailable,
        ),
      ),
    );

    await server.close(force: true);
  });
}
