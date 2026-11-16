import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:jarvis_app/src/core/browser/browser_favicon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('browserFaviconUri', () {
    final page = Uri.parse('http://127.0.0.1:5555/app/index.html');

    test('页面没声明图标就退回同源 /favicon.ico', () {
      expect(
        browserFaviconUri(null, page).toString(),
        'http://127.0.0.1:5555/favicon.ico',
      );
      expect(
        browserFaviconUri('   ', page).toString(),
        'http://127.0.0.1:5555/favicon.ico',
      );
    });

    test('相对路径按页面地址解析', () {
      expect(
        browserFaviconUri('./icon.png', page).toString(),
        'http://127.0.0.1:5555/app/icon.png',
      );
      expect(
        browserFaviconUri('/assets/icon.ico', page).toString(),
        'http://127.0.0.1:5555/assets/icon.ico',
      );
    });

    test('svg 解不出来，直接不给（标签回退地球图标）', () {
      expect(browserFaviconUri('/logo.svg', page), isNull);
      expect(browserFaviconUri('data:image/svg+xml,%3Csvg%2F%3E', page), isNull);
    });

    test('data: 图片放行，非 http(s)/data 的 scheme 一律拒绝', () {
      expect(
        browserFaviconUri('data:image/png;base64,AAAA', page)?.scheme,
        'data',
      );
      expect(browserFaviconUri('blob:http://127.0.0.1:5555/id', page), isNull);
      expect(browserFaviconUri('javascript:alert(1)', page), isNull);
    });

    test('非 http(s) 页面上连兜底地址都没有', () {
      expect(browserFaviconUri(null, Uri.parse('file:///tmp/a.html')), isNull);
    });
  });

  group('decodeFaviconDataUri', () {
    test('解出 base64 内联图标的字节', () {
      final encoded = base64Encode(<int>[1, 2, 3]);
      final bytes = decodeFaviconDataUri(
        Uri.parse('data:image/png;base64,$encoded'),
      );
      expect(bytes, <int>[1, 2, 3]);
    });

    test('非图片与 svg 内联数据不接收', () {
      expect(
        decodeFaviconDataUri(Uri.parse('data:text/plain;base64,AAAA')),
        isNull,
      );
      expect(
        decodeFaviconDataUri(
          Uri.parse('data:image/svg+xml;base64,${base64Encode(<int>[1])}'),
        ),
        isNull,
      );
    });
  });

  group('BrowserFaviconLoader', () {
    test('命中缓存返回同一份字节，且只下载一次', () async {
      var calls = 0;
      final icon = Uint8List.fromList(<int>[7]);
      final loader = BrowserFaviconLoader(
        fetcher: (uri) async {
          calls++;
          return icon;
        },
      );
      final iconUri = Uri.parse('https://a.test/i.png');

      final firstBytes = await loader.load(iconUri);
      final secondBytes = await loader.load(iconUri);

      expect(calls, 1);
      expect(
        firstBytes,
        same(secondBytes),
        reason: '同一实例，MemoryImage 才不会反复解码同一张图',
      );
    });

    test('同一张图并发请求只下载一次', () async {
      var calls = 0;
      final gate = Completer<Uint8List?>();
      final loader = BrowserFaviconLoader(
        fetcher: (uri) {
          calls++;
          return gate.future;
        },
      );
      final iconUri = Uri.parse('https://a.test/i.png');

      final both = Future.wait(<Future<Uint8List?>>[
        loader.load(iconUri),
        loader.load(iconUri),
      ]);
      gate.complete(Uint8List.fromList(<int>[1]));
      final results = await both;

      expect(calls, 1);
      expect(results.first, same(results.last));
    });

    test('超过容量按最久未用淘汰', () async {
      var calls = 0;
      final loader = BrowserFaviconLoader(
        cacheSize: 1,
        fetcher: (uri) async {
          calls++;
          return Uint8List.fromList(<int>[1]);
        },
      );

      await loader.load(Uri.parse('https://a.test/1.png'));
      await loader.load(Uri.parse('https://b.test/2.png'));
      await loader.load(Uri.parse('https://a.test/1.png'));

      expect(calls, 3, reason: '只留一条，最早的被挤掉');
    });

    test('失败结果也记下来，不反复重试注定失败的地址', () async {
      var calls = 0;
      final loader = BrowserFaviconLoader(
        fetcher: (uri) async {
          calls++;
          return null;
        },
      );
      final iconUri = Uri.parse('https://a.test/missing.png');

      expect(await loader.load(iconUri), isNull);
      expect(await loader.load(iconUri), isNull);

      expect(calls, 1);
    });

    test('data: 图标由本地解码，不走网络', () async {
      // 不注入 fetcher：走内置实现，data 分支在发起任何请求之前就解码完毕。
      final loader = BrowserFaviconLoader();
      final encoded = base64Encode(<int>[4, 5]);

      final bytes = await loader.load(
        Uri.parse('data:image/png;base64,$encoded'),
      );

      expect(bytes, <int>[4, 5]);
    });
  });
}
