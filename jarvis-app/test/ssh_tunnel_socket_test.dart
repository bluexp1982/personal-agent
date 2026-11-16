import 'dart:io';

import 'package:jarvis_app/src/core/ssh/ssh_tunnel_socket.dart';
import 'package:flutter_test/flutter_test.dart';

/// 起一个只会回显二进制帧的"假隧道"。
Future<_FakeTunnelServer> _server({bool upgrade = true}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <WebSocket>[];
  server.listen((request) async {
    if (!upgrade) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.listen((dynamic event) {
      if (event is List<int>) {
        socket.add(event);
      }
    });
  });

  return _FakeTunnelServer(server, sockets);
}

class _FakeTunnelServer {
  _FakeTunnelServer(this.http, this.sockets);

  final HttpServer http;
  final List<WebSocket> sockets;

  Uri get uri => Uri.parse('ws://127.0.0.1:${http.port}/api/ssh');

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await http.close(force: true);
  }
}

void main() {
  test('二进制帧双向透传：写进去的字节原样从 stream 出来', () async {
    final server = await _server();
    final httpClient = HttpClient();
    addTearDown(() async {
      httpClient.close(force: true);
      await server.close();
    });

    final tunnel = await SshTunnelSocket.connect(
      uri: server.uri,
      token: 'token-1',
      httpClient: httpClient,
    );
    addTearDown(tunnel.close);

    tunnel.sink.add(<int>[1, 2, 3, 4]);
    final echoed = await tunnel.stream.first.timeout(
      const Duration(seconds: 3),
    );

    expect(echoed, <int>[1, 2, 3, 4]);
  });

  test('关闭后 done 完成，重复关闭不会抛', () async {
    final server = await _server();
    final httpClient = HttpClient();
    addTearDown(() async {
      httpClient.close(force: true);
      await server.close();
    });

    final tunnel = await SshTunnelSocket.connect(
      uri: server.uri,
      token: 'token-1',
      httpClient: httpClient,
    );

    await tunnel.close();
    await tunnel.close();
    await tunnel.done.timeout(const Duration(seconds: 3));
  });

  test('服务端拒绝升级时连接失败', () async {
    final server = await _server(upgrade: false);
    final httpClient = HttpClient();
    addTearDown(() async {
      httpClient.close(force: true);
      await server.close();
    });

    await expectLater(
      SshTunnelSocket.connect(
        uri: server.uri,
        token: 'token-1',
        httpClient: httpClient,
      ),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('收到文本帧视为协议错误并关闭连接', () async {
    final server = await _server();
    final httpClient = HttpClient();
    addTearDown(() async {
      httpClient.close(force: true);
      await server.close();
    });

    final tunnel = await SshTunnelSocket.connect(
      uri: server.uri,
      token: 'token-1',
      httpClient: httpClient,
    );
    // 先订阅，否则错误没有接收者。
    final done = expectLater(
      tunnel.done,
      throwsA(isA<SshTunnelProtocolError>()),
    );

    server.sockets.single.add('not allowed');
    await done;
  });
}
