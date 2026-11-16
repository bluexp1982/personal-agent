import 'package:jarvis_app/src/core/browser/browser_models.dart';
import 'package:jarvis_app/src/core/browser/browser_targets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseBrowserInput', () {
    test('纯端口跟随来源徽标，默认走服务器隧道', () {
      final target = parseBrowserInput('3000', source: BrowserSource.server);
      expect(target, isA<ServerPortTarget>());
      expect((target! as ServerPortTarget).host, '127.0.0.1');
      expect((target as ServerPortTarget).port, 3000);

      final local = parseBrowserInput('5173', source: BrowserSource.client);
      expect(local, isA<ClientPortTarget>());
      expect((local! as ClientPortTarget).port, 5173);
    });

    test('纯端口在互联网来源下按搜索处理', () {
      final target = parseBrowserInput('3000', source: BrowserSource.internet);
      expect(target, isA<InternetTarget>());
      expect(
        (target! as InternetTarget).uri.host,
        'www.bing.com',
        reason: '端口在互联网来源下没有意义，不该打开一个必然失败的地址',
      );
    });

    test('host:port 跟随来源', () {
      final server = parseBrowserInput(
        'localhost:3000',
        source: BrowserSource.server,
      );
      expect(server, isA<ServerPortTarget>());

      final client = parseBrowserInput(
        '127.0.0.1:5173',
        source: BrowserSource.client,
      );
      expect(client, isA<ClientPortTarget>());

      final internet = parseBrowserInput(
        'example.com:8080',
        source: BrowserSource.internet,
      );
      expect(internet, isA<InternetTarget>());
      expect((internet! as InternetTarget).uri.toString(), 'http://example.com:8080/');
    });

    test('host:port/path 保留路径，重新粘贴地址不会丢页面', () {
      final target = parseBrowserInput(
        'localhost:3000/about?x=1',
        source: BrowserSource.server,
      );
      expect(target, isA<ServerPortTarget>());
      expect((target! as ServerPortTarget).path, '/about?x=1');
      expect(target.address, 'localhost:3000/about?x=1');
    });

    test('完整 URL 直接打开，无协议域名补 https', () {
      final full = parseBrowserInput(
        'https://example.com/docs?q=1',
        source: BrowserSource.internet,
      );
      expect((full! as InternetTarget).uri.toString(), 'https://example.com/docs?q=1');

      final bare = parseBrowserInput('example.com', source: BrowserSource.server);
      expect((bare! as InternetTarget).uri.toString(), 'https://example.com');
    });

    test('本地路径与 file:// 都落到本机目录', () {
      final absolute = parseBrowserInput(
        '/tmp/site',
        source: BrowserSource.internet,
      );
      expect(absolute, isA<ClientDirectoryTarget>());
      expect((absolute! as ClientDirectoryTarget).path, '/tmp/site');

      final fileUri = parseBrowserInput(
        'file:///tmp/site/',
        source: BrowserSource.internet,
      );
      expect(fileUri, isA<ClientDirectoryTarget>());
    });

    test('含空格的输入当搜索词', () {
      final target = parseBrowserInput('flutter webview 用法', source: BrowserSource.server);
      expect(target, isA<InternetTarget>());
      final uri = (target! as InternetTarget).uri;
      expect(uri.host, 'www.bing.com');
      expect(uri.queryParameters['q'], 'flutter webview 用法');
    });

    test('空输入与非法端口返回 null', () {
      expect(parseBrowserInput('   ', source: BrowserSource.server), isNull);
      expect(parseBrowserInput('example.com:99999', source: BrowserSource.server), isNull);
      expect(parseBrowserInput('0', source: BrowserSource.server), isNull);
    });

    test('IPv6 目标拼隧道参数要加方括号', () {
      const target = ServerPortTarget(host: '::1', port: 8080);
      expect(tunnelTarget(target), '[::1]:8080');
      expect(target.address, 'localhost:8080');
    });
  });

  group('browserInputFromUrl', () {
    test('本机完整地址去掉 scheme，按服务器隧道打开', () {
      final input = browserInputFromUrl('http://localhost:3000/app?x=1');
      expect(input, 'localhost:3000/app?x=1');

      final target = parseBrowserInput(input, source: BrowserSource.server);
      expect(
        target,
        isA<ServerPortTarget>(),
        reason: 'dev server 在服务端机器上，不能被当成客户端直连',
      );
      expect((target! as ServerPortTarget).port, 3000);
    });

    test('回环 IP 与 IPv6 同样处理', () {
      expect(browserInputFromUrl('http://127.0.0.1:5173/'), '127.0.0.1:5173/');
      expect(browserInputFromUrl('http://[::1]:8080/'), '[::1]:8080/');
    });

    test('公网地址原样保留', () {
      expect(
        browserInputFromUrl('https://example.com/docs'),
        'https://example.com/docs',
      );
    });

    test('缺端口时按 scheme 补默认端口', () {
      expect(browserInputFromUrl('https://localhost/'), 'localhost:443/');
    });
  });

  group('portAddress', () {
    test('隐藏内部桥接端口，保留路径与查询', () {
      final address = portAddress(
        host: '127.0.0.1',
        port: 3000,
        uri: Uri.parse('http://127.0.0.1:51234/users?page=2#top'),
      );
      expect(address, 'localhost:3000/users?page=2#top');
    });

    test('根路径不显示多余的斜杠', () {
      final address = portAddress(
        host: 'localhost',
        port: 5173,
        uri: Uri.parse('http://127.0.0.1:51234/'),
      );
      expect(address, 'localhost:5173');
    });
  });
}
