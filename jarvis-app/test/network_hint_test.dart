import 'package:jarvis_app/src/core/api_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// 连不上时的提示必须能直接指导下一步动作。
///
/// 这条曾经是硬编码的"默认 http://127.0.0.1:8787"，在手机上等于废话：
/// 手机连的是电脑的局域网地址，而且必须走 https。
void main() {
  group('network 错误提示', () {
    test('带上实际尝试的地址', () {
      final error = ApiException.network(
        'SocketException',
        baseUrl: 'https://192.168.1.10:8788',
      );
      expect(error.userMessage, contains('https://192.168.1.10:8788'));
      expect(error.retryable, isTrue);
      expect(error.code, 'network_error');
    });

    test('明文 http + 局域网地址时提示改用 https', () {
      final error = ApiException.network(
        'SocketException',
        baseUrl: 'http://192.168.1.10:8788',
      );
      expect(error.userMessage, contains('https://'));
      expect(error.userMessage, contains('0.0.0.0'));
    });

    test('回环地址不提示 https（桌面开发就是明文回环）', () {
      final error = ApiException.network(
        'SocketException',
        baseUrl: 'http://127.0.0.1:8787',
      );
      expect(error.userMessage, isNot(contains('必须用 https')));
    });

    test('没有地址时退化为通用提示，不报错', () {
      final error = ApiException.network('SocketException');
      expect(error.userMessage, contains('确认服务已启动'));
    });

    test('errno 65 时提示本地网络权限而不是"服务没启动"', () {
      // iOS 没拿到本地网络权限时就是这个错误，查服务端是白费力气
      final error = ApiException.network(
        'SocketException: Connection failed (OS Error: No route to host, '
        'errno = 65), address = 172.16.0.189, port = 8788',
        baseUrl: 'https://172.16.0.189:8788',
      );
      expect(error.userMessage, contains('本地网络'));
      expect(error.userMessage, contains('同一 Wi-Fi'));
    });

    test('普通连接被拒不带本地网络提示', () {
      final error = ApiException.network(
        'SocketException: Connection refused (OS Error: Connection refused, '
        'errno = 61)',
        baseUrl: 'https://172.16.0.189:8788',
      );
      expect(error.userMessage, isNot(contains('本地网络')));
    });
  });
}
