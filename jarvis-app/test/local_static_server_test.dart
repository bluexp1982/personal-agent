import 'dart:convert';
import 'dart:io';

import 'package:jarvis_app/src/core/browser/local_static_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// 起一个临时站点目录，返回 (根目录, 清理函数)。
Future<Directory> _fixture() async {
  final dir = await Directory.systemTemp.createTemp('pa-browser-');
  await File('${dir.path}/index.html').writeAsString(
    '<!doctype html><title>demo</title><h1>hello</h1>',
  );
  await File('${dir.path}/app.js').writeAsString('console.log(1);');
  await File('${dir.path}/.env').writeAsString('SECRET=1');
  await Directory('${dir.path}/sub').create();
  await File('${dir.path}/sub/a.txt').writeAsString('a');
  return dir;
}

Future<HttpClientResponse> _get(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  bool followRedirects = true,
}) async {
  final request = await client.openUrl(method, uri);
  request.followRedirects = followRedirects;
  return request.close();
}

Future<String> _body(HttpClientResponse response) async {
  return response.transform(utf8.decoder).join();
}

void main() {
  late Directory dir;
  late LocalStaticServer server;
  late HttpClient client;

  setUp(() async {
    dir = await _fixture();
    server = await LocalStaticServer.start(root: dir.path);
    client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    await dir.delete(recursive: true);
  });

  test('根路径返回 index.html，MIME 正确且不缓存', () async {
    final response = await _get(client, server.baseUri);
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'text/html');
    expect(response.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    expect(await _body(response), contains('hello'));
  });

  test('相对资源按扩展名给出 MIME', () async {
    final response = await _get(client, server.baseUri.resolve('app.js'));
    expect(response.statusCode, HttpStatus.ok);
    expect(
      response.headers.contentType?.mimeType,
      'text/javascript',
      reason: '模块脚本必须带 JS MIME，否则 WKWebView 会拒绝执行',
    );
    expect(await _body(response), contains('console.log'));
  });

  test('目录请求补上尾斜杠再列目录', () async {
    final withoutSlash = await _get(
      client,
      server.baseUri.resolve('sub'),
      followRedirects: false,
    );
    expect(withoutSlash.statusCode, HttpStatus.movedPermanently);
    expect(withoutSlash.headers.value(HttpHeaders.locationHeader), contains('/sub/'));

    final listing = await _get(client, server.baseUri.resolve('sub/'));
    expect(listing.statusCode, HttpStatus.ok);
    expect(await _body(listing), contains('a.txt'));
  });

  test('隐藏文件与路径穿越都拿不到', () async {
    final hidden = await _get(client, server.baseUri.resolve('.env'));
    expect(hidden.statusCode, HttpStatus.notFound);
    await hidden.drain<void>();

    final traversal = await _get(
      client,
      Uri.parse('${server.baseUri}..%2Foutside.txt'),
    );
    expect(
      traversal.statusCode,
      anyOf(HttpStatus.forbidden, HttpStatus.notFound),
      reason: '编码后的 .. 不能让静态服务跳出根目录',
    );
    await traversal.drain<void>();
  });

  test('不存在的文件返回 404', () async {
    final response = await _get(client, server.baseUri.resolve('missing.txt'));
    expect(response.statusCode, HttpStatus.notFound);
    await response.drain<void>();
  });

  test('HEAD 只回头不回正文', () async {
    final response = await _get(
      client,
      server.baseUri.resolve('app.js'),
      method: 'HEAD',
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, greaterThan(0));
    expect(await _body(response), isEmpty);
  });

  test('displayPath 去掉随机前缀，供地址栏拼接', () {
    expect(server.displayPath(server.baseUri), '/');
    expect(
      server.displayPath(server.baseUri.resolve('sub/a.txt')),
      '/sub/a.txt',
    );
  });

  test('目录不存在时拒绝启动', () async {
    await expectLater(
      LocalStaticServer.start(root: '${dir.path}/nope'),
      throwsA(isA<LocalStaticException>()),
    );
  });
}
